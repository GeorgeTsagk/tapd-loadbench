#!/usr/bin/env bash
# Measure what the profiling export costs the daemon it measures.
#
# The rates are read from the environment by the patched build, so the same
# binary can run with block and mutex profiling on or off. That is the whole
# reason they were made runtime-gated: this number has to be measured, not
# assumed.
#
# Method: a fixed workload of RPCs driven from inside the container, so client
# process spawn cost is identical across conditions. The primary metric is the
# daemon's own cgroup CPU delta, which isolates daemon cost from client cost;
# wall time is reported as a secondary check. Conditions run off, on, off so
# drift from accumulating state shows up as a difference between the two off
# runs rather than being silently attributed to profiling.
#
# Usage: bench/profiling-overhead.sh [reps] [calls-per-rep]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"
. "$HERE/lib/metrics.sh"

REPS=${1:-3}
CALLS=${2:-120}
NODE=alice-tapd

# One rep: a fixed mix of read RPCs that touch the database, the universe trees
# and signature verification paths.
workload() {
  docker exec "$NODE" sh -c "
    for i in \$(seq 1 $CALLS); do
      tapcli --network regtest assets list       >/dev/null 2>&1
      tapcli --network regtest universe roots     >/dev/null 2>&1
      tapcli --network regtest assets balance     >/dev/null 2>&1
    done"
}

cpu_usec_of() {
  docker exec "$NODE" cat /sys/fs/cgroup/cpu.stat 2>/dev/null \
    | awk '/^usage_usec/{print $2}'
}

# Restart the profiled nodes under a given pair of rates.
set_rates() {
  local block=$1 mutex=$2
  TAPD_BLOCK_PROFILE_RATE="$block" TAPD_MUTEX_PROFILE_FRACTION="$mutex" \
    $COMPOSE up -d --force-recreate alice-tapd bob-tapd >/dev/null 2>&1
  for _ in $(seq 1 90); do
    tapcli "$NODE" getinfo >/dev/null 2>&1 && break; sleep 1
  done
  tapcli "$NODE" getinfo >/dev/null || die "$NODE did not come back up"
  # Warm up, so page cache and prepared statements are not part of the first
  # measured rep.
  workload >/dev/null 2>&1
}

measure() {
  local label=$1 r
  for r in $(seq 1 "$REPS"); do
    local c0 t0 c1 t1
    c0=$(cpu_usec_of); t0=$(date +%s.%N)
    workload
    c1=$(cpu_usec_of); t1=$(date +%s.%N)
    awk -v l="$label" -v r="$r" -v a="$c0" -v b="$c1" -v x="$t0" -v y="$t1" \
      'BEGIN{printf "%-14s rep %d  daemon_cpu %8.3fs  wall %7.3fs\n", l, r, (b-a)/1e6, y-x}'
  done
}

echo "workload: $CALLS iterations x 3 RPCs, $REPS reps per condition, node $NODE"
echo

echo "--- condition: profiling off (block=0 mutex=0) ---"
set_rates 0 0
measure "off-first"

echo
echo "--- condition: profiling on (block=100000ns mutex=1/100) ---"
set_rates 100000 100
measure "on"

echo
echo "--- condition: profiling off again, to expose drift ---"
set_rates 0 0
measure "off-second"

echo
echo "--- condition: on, plus an active CPU profile for the whole window ---"
set_rates 100000 100
cpu_profile_start 600
measure "on+cpuprof"
cpu_profile_stop /tmp "overhead-check"

echo
echo "Restoring configured rates."
set_rates "${TAPD_BLOCK_PROFILE_RATE:-100000}" "${TAPD_MUTEX_PROFILE_FRACTION:-100}"
