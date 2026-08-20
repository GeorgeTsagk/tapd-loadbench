#!/usr/bin/env bash
# Check that the library provides everything the scripts call. A previous edit
# truncated common.sh and removed ensure_federation, which broke deploy.sh and
# silently stopped the cron for three hours.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"; . "$HERE/lib/genconf.sh"; . "$HERE/lib/metrics.sh"

REQUIRED=(die log btc lncli tapcli mine sync_creds health_check ensure_funded
          ensure_federation prom prom_fetch prom_json gen_conf cgroup_memory
          cgroup_cpu all_container_stats capture_profiles capture_all
          grpc_latency sqlite_bytes postgres_bytes proofs_bytes proofs_count
          tapd_metrics snapshot)
missing=()
for f in "${REQUIRED[@]}"; do
  declare -F "$f" >/dev/null || missing+=("$f")
done
if (( ${#missing[@]} )); then
  echo "MISSING functions: ${missing[*]}" >&2
  exit 1
fi

for v in TAPD_NODES LND_NODES PG_DATABASES; do
  [[ -n "${!v:-}" ]] || { echo "MISSING variable: $v" >&2; exit 1; }
done
for a in TAPD_GRPC TAPD_PROM TAPD_DB FEDERATION; do
  declare -p "$a" >/dev/null 2>&1 || { echo "MISSING array: $a" >&2; exit 1; }
done

for s in "$HERE"/*.sh "$HERE"/lib/*.sh; do bash -n "$s" || exit 1; done
echo "selftest OK: ${#REQUIRED[@]} functions, all scripts parse"
