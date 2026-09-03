# shellcheck shell=bash
# Harness-native cases. epoch.sh runs case_<name> when such a function exists,
# in preference to handing the name to the load suite.

# The receiver's confirmed unspent asset set, as a sorted, comparable digest.
#
# Compared before and after a wipe to prove the restore is faithful. The set is
# keyed by asset id, script key and amount rather than counted, because a count
# would pass even if the restore returned different leaves totalling the same.
# Paged, since a plain listing caps at the default page size.
# $2 selects the script key filter: "all" for every type, empty for the RPC
# default. The default is BIP86 only, per ParseScriptKeyTypeQuery, so the two
# differ whenever a key cannot be classified as BIP86.
asset_set_digest() {
  local node=$1 filter=${2:-} mac cert port body offset=0 page=16384 n out="" q=""
  [[ "$filter" == all ]] && q="&script_key_type.all_types=true"
  port=${TAPD_REST[$node]}
  cert="$CREDS/$node/tls.cert"
  mac=$(xxd -p -c9999 "$CREDS/$node/admin.macaroon" 2>/dev/null) || return 1
  while :; do
    body=$(curl -s --max-time 120 --cacert "$cert" \
      -H "Grpc-Metadata-macaroon: $mac" \
      "https://localhost:$port/v1/taproot-assets/assets?limit=$page&offset=$offset$q" \
      2>/dev/null) || return 1
    n=$(printf '%s' "$body" | jq '.assets | length' 2>/dev/null)
    [[ -n "$n" && "$n" != "null" ]] || return 1
    out+=$(printf '%s' "$body" | jq -r '
      .assets[]? | "\(.asset_genesis.asset_id) \(.script_key) \(.amount)"')
    out+=$'\n'
    (( n < page )) && break
    offset=$(( offset + page ))
  done
  printf '%s' "$out" | grep -c . >/dev/null 2>&1 || true
  printf '%s' "$out" | sort
}

# Size of the live backup file a node keeps on disk.
backup_file_bytes() {
  local node=$1
  docker exec "$node" stat -c %s \
    /root/.tapd/data/regtest/assets.backup 2>/dev/null || printf ''
}

# Wipe the receiver's asset state and restore it from its own backup file.
#
# The backup is keyed to the lnd wallet, so only tapd's state can be dropped:
# the lnd node and its seed have to survive or the file cannot be decrypted.
# The v2 file on disk carries stripped proofs plus rehydration hints, so the
# import reads full blocks back from the chain backend rather than talking to a
# universe server. That makes this case a measurement of chain rehydration.
case_backup() {
  local node=$PEER_TAPD

  # Everything has to be confirmed first. The file only holds confirmed unspent
  # leaves, so anything still pending would be legitimately absent after the
  # restore and would look like data loss.
  mine 6
  sleep 5

  local before size_before visible_before
  before=$(asset_set_digest "$node" all) \
    || { echo "cannot read asset set"; return 1; }
  # Counted separately under the RPC default filter, which is BIP86 only. A
  # restore that returns the leaves but loses their script key type leaves this
  # at zero while the set above matches, so recording both makes that visible
  # instead of it passing silently or failing the whole case.
  visible_before=$(asset_set_digest "$node" | grep -c . || true)
  size_before=$(backup_file_bytes "$node")
  local leaves; leaves=$(printf '%s' "$before" | grep -c . || true)
  echo "before: $leaves leaves, backup ${size_before:-?} bytes"

  # Keep a copy off the container: the wipe destroys the volume it lives on.
  local tmp="$RUNDIR/assets.backup"
  docker cp "$node:/root/.tapd/data/regtest/assets.backup" "$tmp" >/dev/null \
    || { echo "no backup file to restore from"; return 1; }

  # Drop tapd's state. The container is recreated so it comes up against the
  # same lnd with an empty database and no proofs.
  local w0 w1
  w0=$(date +%s.%N)
  $COMPOSE stop "$node" >/dev/null 2>&1
  $COMPOSE rm -f "$node" >/dev/null 2>&1
  docker volume rm "tapbench_$node" >/dev/null 2>&1 \
    || { echo "could not remove volume tapbench_$node"; return 1; }
  if [[ "${TAPD_DB[$node]}" == postgres ]]; then
    docker exec pg psql -U lightning -d postgres -q \
      -c "DROP DATABASE IF EXISTS \"${TAPD_PGDB[$node]}\" WITH (FORCE)" >/dev/null
    docker exec pg psql -U lightning -d postgres -q \
      -c "CREATE DATABASE \"${TAPD_PGDB[$node]}\"" >/dev/null
  fi
  $COMPOSE up -d "$node" >/dev/null 2>&1
  local i
  for i in $(seq 1 180); do tapcli "$node" getinfo >/dev/null 2>&1 && break; sleep 1; done
  tapcli "$node" getinfo >/dev/null || { echo "$node did not come back"; return 1; }
  w1=$(date +%s.%N)
  sync_creds >/dev/null 2>&1

  # The restored node must start empty, or the wipe did not take and the
  # comparison afterwards would be meaningless.
  local empty; empty=$(asset_set_digest "$node" all | grep -c . || true)
  if (( empty != 0 )); then
    echo "wipe incomplete: $node still reports $empty leaves"
    return 1
  fi

  # The measurement: import the file and wait for it to be applied.
  local i0 i1 resp
  i0=$(date +%s.%N)
  resp=$(docker exec -i "$node" tapcli --network regtest assets backup import \
    --backup_file - < "$tmp" 2>&1) || { echo "import failed: $resp"; return 1; }
  i1=$(date +%s.%N)

  local imported skipped
  imported=$(printf '%s' "$resp" | jq -r '.num_imported // 0' 2>/dev/null || echo 0)
  skipped=$(printf '%s' "$resp" | jq -r '.num_skipped // 0' 2>/dev/null || echo 0)

  local after visible_after
  after=$(asset_set_digest "$node" all) \
    || { echo "cannot re-read asset set"; return 1; }
  visible_after=$(asset_set_digest "$node" | grep -c . || true)

  # The updater rewrites the file after importing, on a debounce. Give it a
  # moment so the recorded size is the restored wallet's, not the empty one it
  # started from.
  sleep 5
  local size_after; size_after=$(backup_file_bytes "$node")

  CASE_DETAIL=$(jq -cn \
    --argjson leaves "$leaves" \
    --argjson backup_bytes "${size_before:-null}" \
    --argjson backup_bytes_after "${size_after:-null}" \
    --argjson wipe_s "$(awk -v a="$w0" -v b="$w1" 'BEGIN{printf "%.2f", b-a}')" \
    --argjson import_s "$(awk -v a="$i0" -v b="$i1" 'BEGIN{printf "%.2f", b-a}')" \
    --argjson imported "${imported:-0}" --argjson skipped "${skipped:-0}" \
    --argjson visible_before "${visible_before:-0}" \
    --argjson visible_after "${visible_after:-0}" \
    '$ARGS.named')
  echo "detail: $CASE_DETAIL"

  # The assertion. A diff rather than a count, so a restore that returns the
  # wrong leaves in the right number still fails.
  if [[ "$before" != "$after" ]]; then
    echo "RESTORE MISMATCH"
    diff <(printf '%s' "$before") <(printf '%s' "$after") | head -20
    return 1
  fi
  echo "restore verified: $leaves leaves match, imported=$imported skipped=$skipped"
  if (( visible_before != visible_after )); then
    echo "NOTE: default ListAssets shows $visible_after of $visible_before" \
      "restored leaves; the script key type is not preserved by the restore"
  fi
}
