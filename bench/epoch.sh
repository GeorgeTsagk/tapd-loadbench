#!/usr/bin/env bash
# Run one benchmark epoch against the persistent tapbench regtest network and
# append one JSON record to data/epochs.jsonl.
#
# The network is never reset. Each epoch adds assets, transfers and universe
# leaves on top of everything prior epochs created, so the series measures how
# tapd behaves as its state grows, not just one-shot throughput.
#
# Usage: bench/epoch.sh [--cases "mintV2 sendV2"] [--dry-run]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
set -a; . "$HERE/config.env"; set +a
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
. "$HERE/lib/genconf.sh"
. "$HERE/lib/metrics.sh"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases)   CASES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

DATA="$REPO_ROOT/data/epochs.jsonl"
LOCK="$REPO_ROOT/.bench.lock"
LOADTEST="$HERE/bin/loadtest"
[[ -x "$LOADTEST" ]] || die "loadtest binary missing at $LOADTEST (see bench/build.sh)"

# Cron can fire while a previous epoch is still running. Skip rather than
# queue: two concurrent epochs would interleave their state changes and both
# records would be meaningless.
exec 9>"$LOCK"
flock -n 9 || { echo "another epoch is running, skipping"; exit 0; }

mkdir -p "$(dirname "$DATA")"
touch "$DATA"
EPOCH=$(( $(wc -l < "$DATA") + 1 ))

# The minter is fixed. Alternating it does not work: the send case calls the
# taproot-assets itest helper SyncUniverses, which polls until the two nodes'
# universe root sets are *equal*. That only holds while one node has no assets
# of its own. With both nodes minting, the sets diverge permanently and the case
# spins until its timeout. The assertion lives in the vendored taproot-assets
# itest package, so it cannot be relaxed from the load suite.
#
# The cost is that alice (sqlite) is always the minter and bob (postgres) always
# the receiver, so those two are not a like-for-like backend comparison. That
# comparison is made instead between uni-tapd and uni2-tapd, which hold the same
# federation content under the same sync load on different backends.
MINTER_TAPD=alice-tapd; MINTER_LND=alice
PEER_TAPD=bob-tapd;     PEER_LND=bob

RUNDIR="$REPO_ROOT/logs/epoch-$(printf '%05d' "$EPOCH")"
mkdir -p "$RUNDIR"

log "epoch $EPOCH: minter=$MINTER_TAPD peer=$PEER_TAPD cases='$CASES'"

log "health check"
health_check
sync_creds
for n in $LND_NODES; do ensure_funded "$n" "$MIN_LND_BALANCE"; done

gen_conf "$RUNDIR/loadtest.conf" \
  "$MINTER_TAPD" "$MINTER_LND" "$PEER_TAPD" "$PEER_LND"

if (( DRY_RUN )); then
  log "dry run: config written to $RUNDIR/loadtest.conf, stopping"
  exit 0
fi

TAPD_VERSION=$(tapcli "$MINTER_TAPD" getinfo | jq -r .version)
LND_VERSION=$(lncli "$MINTER_LND" getinfo | jq -r .version)
BTC_VERSION=$(btc -version 2>/dev/null | head -1 | grep -oP 'v\d+\.\d+\.\d+' || echo unknown)

log "collecting before snapshot"
BEFORE=$(snapshot)

STARTED=$(date -u +%FT%TZ)
T0=$(date +%s.%N)

CASE_RESULTS="[]"
for case_name in $CASES; do
  log "running case $case_name"
  c0=$(date +%s.%N)
  status=pass
  # The binary insists on finding loadtest.conf in its working directory.
  ( cd "$RUNDIR" && "$LOADTEST" -test.v \
      -test.run "TestPerformance/$case_name" \
      -test.timeout "$CASE_TIMEOUT" ) \
    > "$RUNDIR/$case_name.log" 2>&1 || status=fail
  c1=$(date +%s.%N)
  dur=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.2f", b-a}')

  # A case that gets skipped (no matching -test.run) reports success but does
  # no work, which would silently poison the series. Detect it.
  if ! grep -q -- "--- PASS: TestPerformance/$case_name\|--- FAIL: TestPerformance/$case_name" \
      "$RUNDIR/$case_name.log"; then
    status=skipped
  fi

  log "  $case_name: $status in ${dur}s"
  CASE_RESULTS=$(jq -cn --argjson acc "$CASE_RESULTS" --arg n "$case_name" \
    --arg s "$status" --argjson d "$dur" \
    '$acc + [{name: $n, status: $s, duration_s: $d}]')
done

T1=$(date +%s.%N)
TOTAL=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.2f", b-a}')
FINISHED=$(date -u +%FT%TZ)

log "collecting after snapshot"
AFTER=$(snapshot)

# Per-node growth for this epoch. This is the headline number: absolute db size
# is dominated by each backend's fixed baseline, the delta is what compares.
DELTA=$(jq -cn --argjson b "$BEFORE" --argjson a "$AFTER" '
  reduce ($a.tapd | keys[]) as $k ({};
    . + { ($k): {
      db_bytes:      ($a.tapd[$k].db_bytes      - $b.tapd[$k].db_bytes),
      proofs_bytes:  ($a.tapd[$k].proofs_bytes  - $b.tapd[$k].proofs_bytes),
      proofs_files:  ($a.tapd[$k].proofs_files  - $b.tapd[$k].proofs_files),
      assets:        ($a.tapd[$k].assets        - $b.tapd[$k].assets),
      universe_roots:($a.tapd[$k].universe_roots - $b.tapd[$k].universe_roots),
      universe_leaves:($a.tapd[$k].universe_leaves - $b.tapd[$k].universe_leaves),
      grpc_calls:    ($a.tapd[$k].grpc_calls    - $b.tapd[$k].grpc_calls)
    }}) +
  # CPU time is cumulative in the cgroup, so consumption for one epoch is the
  # difference between the two snapshots. Memory is a level, not a total, and so
  # has no delta.
  { containers: (reduce (($a.containers // {}) | keys[]) as $k ({};
      . + { ($k): {
        cpu_usec:        (($a.containers[$k].cpu_usec        // 0) - ($b.containers[$k].cpu_usec        // 0)),
        cpu_user_usec:   (($a.containers[$k].cpu_user_usec   // 0) - ($b.containers[$k].cpu_user_usec   // 0)),
        cpu_system_usec: (($a.containers[$k].cpu_system_usec // 0) - ($b.containers[$k].cpu_system_usec // 0))
      }})) }')

RECORD=$(jq -cn \
  --argjson epoch "$EPOCH" \
  --arg started_at "$STARTED" \
  --arg finished_at "$FINISHED" \
  --argjson duration_s "$TOTAL" \
  --arg schema_note "$SCHEMA_NOTE" \
  --arg tapd_version "$TAPD_VERSION" \
  --arg lnd_version "$LND_VERSION" \
  --arg btc_version "$BTC_VERSION" \
  --arg minter "$MINTER_TAPD" \
  --arg receiver "$PEER_TAPD" \
  --argjson cases "$CASE_RESULTS" \
  --argjson config "$(jq -cn \
      --argjson mint_batch_size "$MINT_BATCH_SIZE" \
      --argjson mint_total_groups "$MINT_TOTAL_GROUPS" \
      --argjson send_num_sends "$SEND_NUM_SENDS" \
      --argjson send_num_assets "$SEND_NUM_ASSETS" \
      --arg send_addr_version "$SEND_ADDR_VERSION" \
      --arg sync_type "$SYNC_TYPE" \
      --argjson sync_num_clients "$SYNC_NUM_CLIENTS" \
      --argjson sync_page_size "$SYNC_PAGE_SIZE" \
      '$ARGS.named')" \
  --argjson before "$BEFORE" \
  --argjson after "$AFTER" \
  --argjson delta "$DELTA" \
  '{epoch: $epoch, started_at: $started_at, finished_at: $finished_at,
    duration_s: $duration_s, schema_note: $schema_note,
    versions: {tapd: $tapd_version, lnd: $lnd_version, bitcoind: $btc_version},
    roles: {minter: $minter, receiver: $receiver},
    config: $config, cases: $cases,
    before: $before, after: $after, delta: $delta}')

echo "$RECORD" >> "$DATA"
echo "$RECORD" | jq . > "$RUNDIR/record.json"

echo
echo "=== epoch $EPOCH summary ==="
echo "$RECORD" | jq -r '
  "duration: \(.duration_s)s   tapd \(.versions.tapd)   minter \(.roles.minter)",
  "cases:",
  (.cases[] | "  \(.name): \(.status) \(.duration_s)s"),
  "growth this epoch:",
  (.delta | to_entries[] | "  \(.key): db +\(.value.db_bytes)B  proofs +\(.value.proofs_bytes)B  assets +\(.value.assets)"),
  "totals:",
  (.after.tapd | to_entries[] | "  \(.key) (\(.value.backend)): db \(.value.db_bytes)B  assets \(.value.assets)  roots \(.value.universe_roots)")'

# Fail loudly so a cron wrapper can react, but only after the record is
# written: a failed epoch is still data.
if echo "$CASE_RESULTS" | jq -e 'any(.[]; .status != "pass")' >/dev/null; then
  echo
  echo "one or more cases did not pass"
  exit 1
fi
