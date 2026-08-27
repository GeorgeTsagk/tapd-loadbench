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
# Asset and group counts, paged.
#
# tapcli cannot do this. ListAssets applies DefaultAssetQueryLimit=512 when the
# limit is unset, and tapcli exposes neither the offset nor the limit flag, so
# "assets list | length" silently plateaus at exactly 512 and every count
# derived from it goes wrong without any error. It did, from epoch 25 of the v2
# series onward, where the true figure was already 2484.
#
# REST takes both parameters, so page through it at MaxAssetQueryLimit and stop
# on the first short page. Group keys are collected from the same pages rather
# than a second pass, since the response is the expensive part.
tapd_asset_counts() {
  local node=$1
  local mac cert port
  port=${TAPD_REST[$node]}
  cert="$CREDS/$node/tls.cert"
  [[ -r "$cert" && -r "$CREDS/$node/admin.macaroon" ]] || { printf 'null'; return; }
  mac=$(xxd -p -c9999 "$CREDS/$node/admin.macaroon" 2>/dev/null) || { printf 'null'; return; }

  local offset=0 page=16384 total=0 n body k groupkeys=""
  while :; do
    body=$(curl -s --max-time 120 --cacert "$cert" \
      -H "Grpc-Metadata-macaroon: $mac" \
      "https://localhost:$port/v1/taproot-assets/assets?limit=$page&offset=$offset" \
      2>/dev/null) || { printf 'null'; return; }
    n=$(printf '%s' "$body" | jq '.assets | length' 2>/dev/null)
    # A missing or unparseable page means the count is unknown. Reporting a
    # partial total as if it were complete is what produced the 512 plateau.
    [[ -n "$n" && "$n" != "null" ]] || { printf 'null'; return; }
    # Reduce to distinct keys per page before accumulating. A page carries up
    # to 16384 entries but only a handful of distinct groups, and handing the
    # unreduced list to another process overflows the argument limit.
    while IFS= read -r k; do
      [[ -n "$k" ]] && groupkeys+="$k"$'\n'
    done < <(printf '%s' "$body" | jq -r \
      '[.assets[]?.asset_group.tweaked_group_key // empty] | unique[]' 2>/dev/null)
    total=$(( total + n ))
    (( n < page )) && break
    offset=$(( offset + page ))
  done
  local ngroups
  ngroups=$(printf '%s' "$groupkeys" | sort -u | grep -c . || true)
  jq -cn --argjson a "$total" --argjson g "${ngroups:-0}" \
    '{assets: $a, groups: $g}'
}

tapd_metrics() {
  local node=$1
  local backend=${TAPD_DB[$node]}

  # One scrape, reused by every metric below.
  prom_fetch "$node"

  local db_bytes proofs_b proofs_n assets groups roots batches
  db_bytes=$(prom_json "$node" total_db_size)
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

  local counts
  counts=$(tapd_asset_counts "$node")
  assets=$(printf '%s' "$counts" | jq -r '.assets // "null"')
  groups=$(printf '%s' "$counts" | jq -r '.groups // "null"')
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
    --argjson db_bytes "${db_bytes:-null}" \
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
    --argjson heap_bytes "$(prom_json "$node" go_memstats_heap_inuse_bytes)" \
    --argjson goroutines "$(prom_json "$node" go_goroutines)" \
    --argjson grpc_calls "$(prom_json "$node" grpc_server_started_total)" \
    --argjson uni_syncs "$(prom_json "$node" num_total_syncs)" \
    --argjson uni_proofs "$(prom_json "$node" num_total_proofs)" \
    --argjson container "$(echo "${CONTAINER_STATS:-{\}}" | jq -c --arg k "$node" '.[$k] // {}' 2>/dev/null || echo '{}')" \
    --argjson grpc "$(grpc_latency "$node" 2>/dev/null || echo '{}')" \
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
  PROM_CACHE=()

  local out="{}" n
  for n in $TAPD_NODES; do
    out=$(jq -cn --argjson acc "$out" --arg k "$n" --argjson v "$(tapd_metrics "$n")" \
      '$acc + {($k): $v}')
  done
  # WAL checkpoint state for the sqlite nodes. Reported separately from the
  # tapd block because it has no postgres counterpart, and because reported db
  # size alone is blind to it: a stalled checkpoint leaves the main file
  # untouched for days while the WAL grows without bound.
  local wal="{}"
  for n in $TAPD_NODES; do
    [[ "${TAPD_DB[$n]}" == sqlite ]] || continue
    wal=$(jq -cn --argjson acc "$wal" --arg k "$n" \
      --argjson v "$(sqlite_wal_state "$n")" '$acc + {($k): $v}')
  done
  local height
  height=$(btc getblockcount 2>/dev/null || echo 0)
  jq -cn --argjson nodes "$out" --argjson height "${height:-0}" \
    --argjson containers "$CONTAINER_STATS" --argjson wal "$wal" \
    '{block_height: $height, tapd: $nodes, containers: $containers, wal: $wal}'
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
# heap and goroutine are levels, read as-is. allocs, block and mutex are
# cumulative since process start, so a pre/post pair brackets exactly one
# operation. block and mutex are only populated because the patched build
# enables their sample rates, which the stock binary leaves at zero.
PROFILE_KINDS="heap goroutine allocs block mutex"

capture_profiles() {
  local node=$1 dir=$2 label=$3
  mkdir -p "$dir"
  local p
  for p in $PROFILE_KINDS; do
    docker exec "$node" sh -c \
      "curl -s -o /tmp/$p.pb.gz 'localhost:$PPROF_PORT/debug/pprof/$p'" 2>/dev/null || continue
    docker cp "$node:/tmp/$p.pb.gz" "$dir/$node.$label.$p.pb.gz" >/dev/null 2>&1 || true
  done
}

# Open a CPU profile window on every profiled node. The stock ?seconds=N
# handler needs the duration up front, which no operation can supply, so the
# patched build exposes an explicit bracket instead. The seconds argument is
# only a watchdog: if this script dies before the stop call, the daemon stops
# profiling itself rather than sampling forever.
cpu_profile_start() {
  local watchdog=$1 n
  for n in $PPROF_NODES; do
    docker exec "$n" sh -c \
      "curl -s -o /dev/null 'localhost:$PPROF_PORT/debug/cpu/start?seconds=$watchdog'" \
      2>/dev/null || true
  done
}

# Close the window and keep the profile. Named by operation, so the CPU cost of
# one case is a file rather than something to be inferred from an epoch total.
cpu_profile_stop() {
  local dir=$1 label=$2 n
  mkdir -p "$dir"
  for n in $PPROF_NODES; do
    docker exec "$n" sh -c \
      "curl -s -o /tmp/cpu.pb.gz 'localhost:$PPROF_PORT/debug/cpu/stop'" 2>/dev/null || continue
    docker cp "$n:/tmp/cpu.pb.gz" "$dir/$n.$label.cpu.pb.gz" >/dev/null 2>&1 || true
  done
}

# sqlite WAL checkpoint state, read straight out of the wal-index header. This
# is the one metric that would have caught the 3.7 GB never-checkpointed WAL on
# the v0.8.1 minter, where the daemon looked healthy and the reported db size
# was three days stale.
#
# Layout: WalIndexHdr is 48 bytes and stored twice, so WalCkptInfo starts at
# byte 96 with nBackfill, then aReadMark[5]. mxFrame sits at byte 16 of the
# first header copy. Reading the file costs the daemon nothing.
sqlite_wal_state() {
  local node=$1
  local base=/root/.tapd/data/regtest/tapd.db
  local words
  words=$(docker exec "$node" sh -c \
    "[ -f $base-shm ] || exit 1; dd if=$base-shm bs=132 count=1 2>/dev/null | od -An -tu4 -v" \
    2>/dev/null | tr -s ' \n' ' ') || { printf 'null'; return; }
  local sizes
  sizes=$(docker exec "$node" sh -c \
    "stat -c %s $base 2>/dev/null || echo 0; stat -c %s $base-wal 2>/dev/null || echo 0; stat -c %s $base-shm 2>/dev/null || echo 0" \
    2>/dev/null | tr '\n' ' ')
  awk -v words="$words" -v sizes="$sizes" 'BEGIN {
    n = split(words, w, " ")
    split(sizes, z, " ")
    # od prints one leading empty field after the tr squeeze, so word i of the
    # file is w[i+1]. mxFrame is word 4, nBackfill word 24.
    mx = w[5] + 0; nb = w[25] + 0
    printf "{\"mx_frame\":%d,\"n_backfill\":%d,\"unbackfilled\":%d,", mx, nb, mx - nb
    printf "\"db_bytes\":%d,\"wal_bytes\":%d,\"shm_bytes\":%d,", z[1] + 0, z[2] + 0, z[3] + 0
    printf "\"read_marks\":[%d,%d,%d,%d,%d]}", w[26]+0, w[27]+0, w[28]+0, w[29]+0, w[30]+0
  }'
}

# Cumulative CPU microseconds for the containers a case can load. Differencing
# this across a case gives the exact CPU seconds the case cost, which is the
# denominator the CPU profile gets attributed against. Without it a profile
# says where time went in relative terms but never how much there was.
case_cpu() {
  local out="{}" n v
  for n in $PPROF_NODES pg; do
    v=$(docker exec "$n" cat /sys/fs/cgroup/cpu.stat 2>/dev/null \
      | awk '/^usage_usec/{print $2}')
    out=$(jq -cn --argjson acc "$out" --arg k "$n" --argjson v "${v:-0}" \
      '$acc + {($k): $v}')
  done
  printf '%s' "$out"
}

# Reset the postgres statement counters so the next window is attributable.
# pg_stat_statements is cluster-wide, and only the tapd databases use this
# instance, so a global reset is the whole scope.
pg_stat_reset() {
  docker exec pg psql -U lightning -d postgres -q -c \
    "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || true
}

# The queries that dominated the window just closed, by total time. This is the
# direct answer to which statement an operation is waiting on, which previously
# had to be reconstructed by hand from pg_stat_activity samples.
pg_stat_top() {
  local limit=${1:-15}
  docker exec pg psql -U lightning -d postgres -t -A -F$'\t' -c \
    "SELECT d.datname, s.calls, round(s.total_exec_time::numeric, 1),
            round(s.mean_exec_time::numeric, 3), s.rows,
            left(regexp_replace(s.query, '\s+', ' ', 'g'), 160)
     FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
     WHERE d.datname LIKE '%tapd'
     ORDER BY s.total_exec_time DESC LIMIT $limit;" 2>/dev/null \
  | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")) |
      map({db: .[0], calls: (.[1]|tonumber), total_ms: (.[2]|tonumber),
           mean_ms: (.[3]|tonumber), rows: (.[4]|tonumber), query: .[5]})' \
  || printf '[]'
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
