# shellcheck shell=bash
# Metric collection. Sourced by epoch.sh. Every function prints JSON on stdout.

# Bytes used by the sqlite database file and its WAL/SHM sidecars, plus any
# pre-migration backup files tapd leaves behind.
sqlite_bytes() {
  local node=$1
  docker exec "$node" sh -c '
    d=/root/.tapd/data/regtest
    main=0; wal=0; shm=0; bak=0
    for f in "$d"/tapd.db; do [ -f "$f" ] && main=$((main+$(stat -c %s "$f"))); done
    for f in "$d"/tapd.db-wal; do [ -f "$f" ] && wal=$((wal+$(stat -c %s "$f"))); done
    for f in "$d"/tapd.db-shm; do [ -f "$f" ] && shm=$((shm+$(stat -c %s "$f"))); done
    for f in "$d"/tapd.db.*.backup; do [ -f "$f" ] && bak=$((bak+$(stat -c %s "$f"))); done
    echo "$main $wal $shm $bak"
  ' 2>/dev/null | awk '{printf "{\"main\":%s,\"wal\":%s,\"shm\":%s,\"backups\":%s}", $1,$2,$3,$4}'
}

# Total size postgres reports for the tapd database, plus the ten largest
# relations. Table sizes are what tell you which subsystem is growing.
postgres_bytes() {
  local db=${1:-bobtapd}
  local total tables
  total=$(docker exec pg psql -U lightning -d "$db" -tAc \
    "SELECT pg_database_size('$db')" 2>/dev/null || echo 0)
  tables=$(docker exec pg psql -U lightning -d "$db" -tAF$'\t' -c \
    "SELECT relname, pg_total_relation_size(c.oid)
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
      ORDER BY 2 DESC LIMIT 10" 2>/dev/null \
    | jq -Rn '[inputs | select(length>0) | split("\t")
               | {(.[0]): (.[1]|tonumber)}] | add // {}')
  jq -cn --argjson total "${total:-0}" --argjson tables "${tables:-\{\}}" \
    '{total: $total, top_tables: $tables}'
}

# Size of the on-disk proof archive. Proof files live outside the DB, so a
# db-size-only view understates real storage growth.
proofs_bytes() {
  docker exec "$1" sh -c \
    'du -sb /root/.tapd/data/regtest/proofs 2>/dev/null | cut -f1' 2>/dev/null \
    | tr -d '\r' | grep -E '^[0-9]+$' || echo 0
}

proofs_count() {
  docker exec "$1" sh -c \
    'find /root/.tapd/data/regtest/proofs -type f 2>/dev/null | wc -l' 2>/dev/null \
    | tr -d '\r' | grep -E '^[0-9]+$' || echo 0
}

# Container resident memory, CPU share and restart count. A rising restart
# count is the signal that the daemon is crash-looping, which would otherwise
# hide behind passing test cases.
container_stats() {
  local node=$1
  local raw mem cpu restarts
  raw=$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "$node" 2>/dev/null)
  mem=$(echo "$raw" | cut -d'|' -f1 | awk '{print $1}')
  cpu=$(echo "$raw" | cut -d'|' -f2 | tr -d '%')
  restarts=$(docker inspect -f '{{.RestartCount}}' "$node" 2>/dev/null || echo 0)
  # MemUsage comes out human-readable (e.g. "84.3MiB"); normalise to bytes.
  local mem_b
  mem_b=$(echo "$mem" | awk '
    /GiB/ { sub(/GiB/,""); printf "%d", $0 * 1024 * 1024 * 1024; exit }
    /MiB/ { sub(/MiB/,""); printf "%d", $0 * 1024 * 1024; exit }
    /KiB/ { sub(/KiB/,""); printf "%d", $0 * 1024; exit }
    /B/   { sub(/B/,"");   printf "%d", $0; exit }
    { print 0 }')
  jq -cn --argjson mem "${mem_b:-0}" --argjson cpu "${cpu:-0}" \
    --argjson restarts "${restarts:-0}" \
    '{mem_bytes: $mem, cpu_pct: $cpu, restart_count: $restarts}'
}

# Everything about one tapd node.
tapd_metrics() {
  local node=$1
  local backend=${TAPD_DB[$node]}

  local db_bytes proofs_b proofs_n assets groups roots batches
  db_bytes=$(prom "$node" total_db_size)
  proofs_b=$(proofs_bytes "$node")
  proofs_n=$(proofs_count "$node")

  # universe stats is the authoritative universe size. The equivalent
  # Prometheus gauges are background-aggregated and lag behind reality.
  local ustats leaves ugroups
  ustats=$(tapcli "$node" universe stats 2>/dev/null || echo '{}')
  leaves=$(echo "$ustats" | jq -r '(.num_total_proofs // "0") | tonumber')
  ugroups=$(echo "$ustats" | jq -r '(.num_total_groups // "0") | tonumber')
  # The multiverse root is a commitment to the node's entire universe state, so
  # two nodes holding the same content produce the same hash. That is an exact
  # equality test, unlike the leaf count above, which comes from tapd's
  # background stats aggregator and lags behind reality.
  local mv mvsum mvroot
  mv=$(tapcli "$node" universe multiverse 2>/dev/null || echo '{}')
  mvsum=$(echo "$mv" | jq -r '(.multiverse_root.root_sum // "0") | tonumber')
  mvroot=$(echo "$mv" | jq -r '.multiverse_root.root_hash // ""')

  assets=$(tapcli "$node" assets list 2>/dev/null | jq '.assets|length' || echo 0)
  groups=$(tapcli "$node" assets list 2>/dev/null \
    | jq '[.assets[]?.asset_group.tweaked_group_key // empty]|unique|length' || echo 0)
  roots=$(tapcli "$node" universe roots 2>/dev/null | jq '.universe_roots|length' || echo 0)
  batches=$(tapcli "$node" assets mint batches 2>/dev/null | jq '.batches|length' || echo 0)

  local storage
  if [[ "$backend" == "sqlite" ]]; then
    storage=$(jq -cn --argjson f "$(sqlite_bytes "$node")" '{sqlite: $f}')
  else
    storage=$(jq -cn --argjson p "$(postgres_bytes "${TAPD_PGDB[$node]}")" '{postgres: $p}')
  fi

  jq -cn \
    --arg backend "$backend" \
    --argjson db_bytes "${db_bytes:-0}" \
    --argjson storage "$storage" \
    --argjson proofs_bytes "${proofs_b:-0}" \
    --argjson proofs_files "${proofs_n:-0}" \
    --argjson assets "${assets:-0}" \
    --argjson groups "${groups:-0}" \
    --argjson universe_roots "${roots:-0}" \
    --argjson universe_leaves "${leaves:-0}" \
    --argjson universe_groups "${ugroups:-0}" \
    --argjson multiverse_sum "${mvsum:-0}" \
    --arg multiverse_root "${mvroot:-}" \
    --argjson mint_batches "${batches:-0}" \
    --argjson heap_bytes "$(prom "$node" go_memstats_heap_inuse_bytes)" \
    --argjson goroutines "$(prom "$node" go_goroutines)" \
    --argjson grpc_calls "$(prom "$node" grpc_server_started_total)" \
    --argjson uni_syncs "$(prom "$node" num_total_syncs)" \
    --argjson uni_proofs "$(prom "$node" num_total_proofs)" \
    --argjson container "$(container_stats "$node")" \
    '{backend: $backend, db_bytes: $db_bytes, storage: $storage,
      proofs_bytes: $proofs_bytes, proofs_files: $proofs_files,
      assets: $assets, groups: $groups, universe_roots: $universe_roots,
      universe_leaves: $universe_leaves, universe_groups: $universe_groups,
      multiverse_sum: $multiverse_sum, multiverse_root: $multiverse_root,
      mint_batches: $mint_batches, heap_bytes: $heap_bytes,
      goroutines: $goroutines, grpc_calls: $grpc_calls,
      universe_syncs: $uni_syncs, universe_proofs: $uni_proofs,
      container: $container}'
}

# Snapshot of the whole network.
snapshot() {
  local out="{}" n
  for n in $TAPD_NODES; do
    out=$(jq -cn --argjson acc "$out" --arg k "$n" --argjson v "$(tapd_metrics "$n")" \
      '$acc + {($k): $v}')
  done
  local height
  height=$(btc getblockcount 2>/dev/null || echo 0)
  jq -cn --argjson nodes "$out" --argjson height "${height:-0}" \
    '{block_height: $height, tapd: $nodes}'
}
