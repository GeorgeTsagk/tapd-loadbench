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

# Container resident memory, CPU share and restart count for every container in
# the network, in one docker stats call. Done as a batch because docker stats
# takes about a second per invocation, and there are ten of them.
#
# A rising restart count is the signal that a daemon is crash-looping, which
# would otherwise hide behind passing test cases.
ALL_CONTAINERS="bitcoind pg $LND_NODES $TAPD_NODES"
# Memory and CPU straight from the container's cgroup.
#
# anon_bytes is the daemon's own memory and is the figure to read. file_bytes is
# page cache, which here tracks the proof archive being read off disk rather
# than anything the daemon retains.
#
# mem_bytes reproduces what docker stats prints (current less inactive page
# cache) and is kept only so the existing series stays continuous. It counts
# active page cache as daemon memory, 17 MiB on the minter when this was written
# and growing with the archive, which would slowly turn a memory chart into a
# disk cache chart.
#
# mem_peak_bytes is memory.peak, a high water mark. It cannot be reset without
# root, so it is cumulative since the container started rather than a per-epoch
# peak. One that keeps climbing is the leak signal; one that flattens means
# memory use has settled.
cgroup_memory() {
  local node=$1 cid base anon file inact kstack slab current peak
  cid=$(docker inspect -f '{{.Id}}' "$node" 2>/dev/null) || { echo '{}'; return; }

  for base in "/sys/fs/cgroup/system.slice/docker-$cid.scope" \
              "/sys/fs/cgroup/docker/$cid"; do
    [[ -r "$base/memory.current" ]] || continue
    anon=$(awk '/^anon /{print $2}' "$base/memory.stat")
    file=$(awk '/^file /{print $2}' "$base/memory.stat")
    inact=$(awk '/^inactive_file /{print $2}' "$base/memory.stat")
    kstack=$(awk '/^kernel_stack /{print $2}' "$base/memory.stat")
    slab=$(awk '/^slab /{print $2}' "$base/memory.stat")
    current=$(cat "$base/memory.current")
    peak=$(cat "$base/memory.peak" 2>/dev/null || echo 0)
    jq -cn --argjson a "${anon:-0}" --argjson f "${file:-0}" \
      --argjson ks "${kstack:-0}" --argjson sl "${slab:-0}" \
      --argjson c "${current:-0}" --argjson i "${inact:-0}" \
      --argjson p "${peak:-0}" \
      '{anon_bytes: $a, file_bytes: $f, kernel_stack_bytes: $ks, slab_bytes: $sl,
        current_bytes: $c, mem_peak_bytes: $p,
        mem_bytes: (if $c > $i then $c - $i else $c end)}'
    return
  done

  echo '{}'
}

# Cumulative CPU time. These only rise, so the figure worth reading is the
# per-epoch difference, which epoch.sh records as a delta. An instantaneous CPU
# percentage is useless here: it is sampled between runs and always reads zero.
cgroup_cpu() {
  local node=$1 cid base u us sy
  cid=$(docker inspect -f '{{.Id}}' "$node" 2>/dev/null) || { echo '{}'; return; }

  for base in "/sys/fs/cgroup/system.slice/docker-$cid.scope" \
              "/sys/fs/cgroup/docker/$cid"; do
    [[ -r "$base/cpu.stat" ]] || continue
    u=$(awk '/^usage_usec /{print $2}' "$base/cpu.stat")
    us=$(awk '/^user_usec /{print $2}' "$base/cpu.stat")
    sy=$(awk '/^system_usec /{print $2}' "$base/cpu.stat")
    jq -cn --argjson u "${u:-0}" --argjson us "${us:-0}" --argjson sy "${sy:-0}" \
      '{cpu_usec: $u, cpu_user_usec: $us, cpu_system_usec: $sy}'
    return
  done

  echo '{}'
}

all_container_stats() {
  local raw
  # shellcheck disable=SC2086
  raw=$(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' \
    $ALL_CONTAINERS 2>/dev/null)

  local restarts="{}" n
  for n in $ALL_CONTAINERS; do
    restarts=$(jq -cn --argjson acc "$restarts" --arg k "$n" \
      --argjson v "$(docker inspect -f '{{.RestartCount}}' "$n" 2>/dev/null || echo 0)" \
      '$acc + {($k): $v}')
  done

  # MemUsage is human readable ("84.3MiB / 58.5GiB"); normalise the used side.
  echo "$raw" | awk -F'\t' '
    function bytes(v) {
      if (v ~ /GiB/) { sub(/GiB/, "", v); return v * 1073741824 }
      if (v ~ /MiB/) { sub(/MiB/, "", v); return v * 1048576 }
      if (v ~ /KiB/) { sub(/KiB/, "", v); return v * 1024 }
      if (v ~ /B/)   { sub(/B/, "", v);   return v + 0 }
      return 0
    }
    NF >= 3 {
      split($2, m, " ")
      cpu = $3; sub(/%/, "", cpu)
      printf "%s%s\"%s\":{\"mem_bytes\":%d,\"cpu_pct\":%s}", \
        (c++ ? "," : "{"), "", $1, bytes(m[1]), (cpu == "" ? 0 : cpu)
    }
    END { print (c ? "}" : "{}") }
  ' | jq -c --argjson r "$restarts" --argjson m "$(
        mem="{}"
        for n in $ALL_CONTAINERS; do
          mem=$(jq -cn --argjson acc "$mem" --arg k "$n" \
            --argjson v "$(jq -cn --argjson m "$(cgroup_memory "$n")" \
              --argjson c "$(cgroup_cpu "$n")" '$m + $c')" '$acc + {($k): $v}')
        done
        echo "$mem"
      )" \
      'to_entries
       | map({key: .key,
              value: (.value + {restart_count: ($r[.key] // 0)} + ($m[.key] // {}))})
       | from_entries'
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
    --argjson container "$(echo "$CONTAINER_STATS" | jq -c --arg k "$node" '.[$k] // {}')" \
    --argjson grpc "$(grpc_latency "$node")" \
    '{backend: $backend, db_bytes: $db_bytes, storage: $storage,
      proofs_bytes: $proofs_bytes, proofs_files: $proofs_files,
      assets: $assets, groups: $groups, universe_roots: $universe_roots,
      universe_leaves: $universe_leaves, universe_groups: $universe_groups,
      multiverse_sum: $multiverse_sum, multiverse_root: $multiverse_root,
      mint_batches: $mint_batches, heap_bytes: $heap_bytes,
      goroutines: $goroutines, grpc_calls: $grpc_calls,
      universe_syncs: $uni_syncs, universe_proofs: $uni_proofs,
      container: $container, grpc: $grpc}'
}

# Snapshot of the whole network.
snapshot() {
  # One batched docker stats call shared by every node below.
  CONTAINER_STATS=$(all_container_stats)

  local out="{}" n
  for n in $TAPD_NODES; do
    out=$(jq -cn --argjson acc "$out" --arg k "$n" --argjson v "$(tapd_metrics "$n")" \
      '$acc + {($k): $v}')
  done
  local height
  height=$(btc getblockcount 2>/dev/null || echo 0)
  jq -cn --argjson nodes "$out" --argjson height "${height:-0}" \
    --argjson containers "$CONTAINER_STATS" \
    '{block_height: $height, tapd: $nodes, containers: $containers}'
}

# Nodes whose tapd exposes pprof, and the port it listens on inside the
# container. Bound to localhost there, so it is reachable only via docker exec.
PPROF_NODES="alice-tapd bob-tapd"
PPROF_PORT=9091

# Save the raw pprof profiles for one node under a label.
#
# Kept as protobuf rather than text because the useful operations are diffs:
# go tool pprof -base of a pre/post pair around one case says what that case did,
# and a diff across epochs says what is accumulating. Text output cannot do
# either.
capture_profiles() {
  local node=$1 dir=$2 label=$3
  mkdir -p "$dir"
  local p
  for p in heap goroutine allocs; do
    docker exec "$node" sh -c \
      "curl -s -o /tmp/$p.pb.gz 'localhost:$PPROF_PORT/debug/pprof/$p'" 2>/dev/null || continue
    docker cp "$node:/tmp/$p.pb.gz" "$dir/$node.$label.$p.pb.gz" >/dev/null 2>&1 || true
  done
}

# Capture on every profiled node at once.
capture_all() {
  local dir=$1 label=$2 n
  for n in $PPROF_NODES; do
    capture_profiles "$n" "$dir" "$label"
  done
}

# Per-method gRPC latency, from the histogram perfhistograms adds. Recording
# every bucket for 93 methods would be most of the record, so keep count, total
# time and a bucket-interpolated median for the methods that were actually
# called.
grpc_latency() {
  local node=$1
  curl -s --max-time 20 "localhost:${TAPD_PROM[$node]}/metrics" 2>/dev/null | awk '
    /^grpc_server_handling_seconds_count/ {
      m = $0; sub(/.*grpc_method="/, "", m); sub(/".*/, "", m)
      count[m] = $NF
    }
    /^grpc_server_handling_seconds_sum/ {
      m = $0; sub(/.*grpc_method="/, "", m); sub(/".*/, "", m)
      sum[m] = $NF
    }
    END {
      printf "{"
      first = 1
      for (m in count) {
        if (count[m] + 0 == 0) continue
        if (!first) printf ","
        printf "\"%s\":{\"calls\":%d,\"total_s\":%s,\"mean_ms\":%.3f}", \
          m, count[m], sum[m], (sum[m] / count[m]) * 1000
        first = 0
      }
      printf "}"
    }'
}
