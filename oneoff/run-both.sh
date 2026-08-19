#!/usr/bin/env bash
# Wipe the client, sync it from the frozen prsrv, and report every sync cycle in
# order. The first is the cold full sync; later ones are incremental syncs with
# nothing new to fetch, which is the case the PR targets.
set -uo pipefail
ARM=$1 CYCLES=${2:-3}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CO="docker compose -f $HERE/compose.yml"
[[ "$ARM" == "enum" ]] && CO="$CO -f $HERE/arm-enum.yml"
CO="$CO -p pr2202"

$CO stop prcli >/dev/null 2>&1; $CO rm -f prcli >/dev/null 2>&1
docker volume rm pr2202_prcli >/dev/null 2>&1
$CO up -d prcli >/dev/null 2>&1
for i in $(seq 1 60); do
  docker exec prcli tapcli --network regtest getinfo >/dev/null 2>&1 && break; sleep 2
done

docker exec prcli tapcli --network regtest universe federation add \
  --universe_host prsrv:10029 >/dev/null 2>&1

# Wait until we have seen the requested number of completed cycles.
for i in $(seq 1 200); do
  n=$(docker logs prcli 2>&1 | grep -c "Synced new Universe leaves from server")
  [[ "$n" -ge "$CYCLES" ]] && break
  sleep 2
done

docker logs prcli 2>&1 \
  | grep -E "Syncing Universe state with server=prsrv|Synced new Universe leaves from server|Attempting delta sync|sync_type=full|new leaves inserted" \
  > /tmp/arm-$ARM.log

python3 - "$ARM" <<'PY'
import re, sys, json, datetime
arm = sys.argv[1]
lines = open(f"/tmp/arm-{arm}.log").read().splitlines()
ts = lambda l: datetime.datetime.strptime(" ".join(l.split()[:2]), "%Y-%m-%d %H:%M:%S.%f")
cycles, start, leaves, path = [], None, 0, ""
for l in lines:
    if "Syncing Universe state with server=prsrv" in l:
        start, leaves, path = ts(l), 0, ""
    elif "Attempting delta sync" in l:
        path = "delta " + re.search(r"since_seq=\d+", l).group(0)
    elif "sync_type=full" in l:
        path = "enumeration full"
    elif m := re.search(r"(\d+) new leaves inserted", l):
        leaves += int(m.group(1))
    elif "Synced new Universe leaves from server" in l and start:
        cycles.append({"seconds": round((ts(l) - start).total_seconds(), 3),
                       "new_leaves": leaves, "path": path})
        start = None
print(json.dumps({"arm": arm, "cycles": cycles}, indent=2))
PY
