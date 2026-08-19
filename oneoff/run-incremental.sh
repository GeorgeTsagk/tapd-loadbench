#!/usr/bin/env bash
# Measure the sync cost when the client is already up to date, which is the case
# the PR targets: discovery should scale with new data, not total data.
#
# The client keeps its database, so the delta cursor survives. A restart makes the
# federation envoy sync on startup, which is the incremental sync we want to time.
set -uo pipefail
ARM=$1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CO="docker compose -f $HERE/compose.yml"
[[ "$ARM" == "enum" ]] && CO="$CO -f $HERE/arm-enum.yml"
CO="$CO -p pr2202"

mark=$(date -u +%Y-%m-%dT%H:%M:%S)
sleep 1
$CO restart prcli >/dev/null 2>&1

for i in $(seq 1 60); do
  docker exec prcli tapcli --network regtest getinfo >/dev/null 2>&1 && break
  sleep 2
done

for i in $(seq 1 120); do
  docker logs prcli --since "$mark" 2>&1 \
    | grep -qE "Synced new Universe leaves from server|already up to date|no new leaves|delta sync complete" && break
  sleep 1
done
sleep 3

start=$(docker logs prcli --since "$mark" 2>&1 | grep -E "Syncing Universe state with server=prsrv" | head -1 | awk '{print $1" "$2}')
end=$(docker logs prcli --since "$mark" 2>&1 | grep -E "Synced new Universe leaves from server|Sync for UniverseRoot.*complete!" | tail -1 | awk '{print $1" "$2}')
seq_line=$(docker logs prcli --since "$mark" 2>&1 | grep -E "Attempting delta sync|sync_type=full" | head -1 | sed 's/.*UNIV: //')
newleaves=$(docker logs prcli --since "$mark" 2>&1 | grep -oE "[0-9]+ new leaves inserted" | awk '{s+=$1} END{print s+0}')

if [[ -n "$start" && -n "$end" ]]; then
  s=$(date -u -d "$start" +%s.%N); e=$(date -u -d "$end" +%s.%N)
  dur=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}')
else
  dur="null"
fi

jq -cn --arg arm "$ARM" --arg dur "${dur:-null}" --arg sl "$seq_line" \
  --arg nl "${newleaves:-0}" \
  '{arm: $arm, phase: "incremental", seconds: (try ($dur|tonumber) catch null),
    new_leaves: ($nl|tonumber), path: $sl}'
