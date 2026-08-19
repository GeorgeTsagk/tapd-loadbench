#!/usr/bin/env bash
# Run one arm: wipe the client, start it with or without delta sync, time a full
# sync of the universe from prsrv. Timing comes from the daemon log, which has
# millisecond stamps, rather than from polling.
set -uo pipefail
ARM=$1   # enum | delta
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CO="docker compose -f $HERE/compose.yml"
[[ "$ARM" == "enum" ]] && CO="$CO -f $HERE/arm-enum.yml"
CO="$CO -p pr2202"

$CO stop prcli >/dev/null 2>&1
$CO rm -f prcli >/dev/null 2>&1
docker volume rm pr2202_prcli >/dev/null 2>&1
$CO up -d prcli >/dev/null 2>&1

for i in $(seq 1 60); do
  docker exec prcli tapcli --network regtest getinfo >/dev/null 2>&1 && break
  sleep 2
done
docker exec prcli tapcli --network regtest getinfo >/dev/null 2>&1 || { echo "prcli did not start"; exit 1; }

# Confirm the arm is actually configured the way we think it is.
if [[ "$ARM" == "enum" ]]; then
  docker inspect prcli --format '{{range .Config.Cmd}}{{println .}}{{end}}' \
    | grep -q "no-delta-sync" || { echo "arm enum: flag missing"; exit 1; }
else
  docker inspect prcli --format '{{range .Config.Cmd}}{{println .}}{{end}}' \
    | grep -q "no-delta-sync" && { echo "arm delta: flag unexpectedly present"; exit 1; }
fi

docker exec prcli tapcli --network regtest universe federation add \
  --universe_host prsrv:10029 >/dev/null 2>&1

for i in $(seq 1 120); do
  docker logs prcli 2>&1 | grep -q "Synced new Universe leaves from server" && break
  sleep 1
done

start=$(docker logs prcli 2>&1 | grep "Syncing Universe state with server=prsrv" | head -1 | awk '{print $1" "$2}')
end=$(docker logs prcli 2>&1 | grep "Synced new Universe leaves from server" | head -1 | awk '{print $1" "$2}')
path=$(docker logs prcli 2>&1 | grep -E "does not support delta sync|Attempting delta sync|sync_type=full" | head -3 | sed 's/.*UNIV: //' | tr '\n' ';')

if [[ -n "$start" && -n "$end" ]]; then
  s=$(date -u -d "$start" +%s.%N); e=$(date -u -d "$end" +%s.%N)
  dur=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}')
else
  dur="null"
fi

leaves=$(docker exec prcli tapcli --network regtest universe stats 2>/dev/null | jq -r '.num_total_proofs // "0"')
root=$(docker exec prcli tapcli --network regtest universe multiverse 2>/dev/null | jq -r '.multiverse_root.root_hash')
srvroot=$(docker exec prsrv tapcli --network regtest universe multiverse 2>/dev/null | jq -r '.multiverse_root.root_hash')

jq -cn --arg arm "$ARM" --arg dur "$dur" --arg leaves "$leaves" \
  --arg root "$root" --arg srvroot "$srvroot" --arg path "$path" \
  '{arm: $arm, seconds: ($dur|tonumber), leaves: ($leaves|tonumber),
    converged: ($root == $srvroot), root: $root, log_path: $path}'
