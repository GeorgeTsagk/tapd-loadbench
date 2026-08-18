#!/usr/bin/env bash
# Cron entry point. Brings the network up if a reboot took it down, runs one
# epoch, refreshes the site, and commits. Designed to be safe to fire on a
# schedule with no one watching.
#
# Install with:
#   crontab -l | { cat; echo "0 * * * * /workspace/tapd-loadbench/bench/cron.sh"; } | crontab -
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/logs/cron-$STAMP.log"
mkdir -p "$ROOT/logs"

exec > >(tee -a "$LOG") 2>&1

echo "=== cron run $STAMP ==="

# A host reboot leaves the containers stopped even with restart: unless-stopped,
# and a fresh boot may not have run bootstrap. deploy.sh is idempotent.
"$HERE/deploy.sh" || { echo "deploy failed, aborting"; exit 1; }

rc=0
"$HERE/epoch.sh" || rc=$?

"$HERE/render.sh" || echo "render failed (continuing)"

cd "$ROOT"
if [[ -n "$(git status --porcelain data docs 2>/dev/null)" ]]; then
  epoch=$(wc -l < data/epochs.jsonl)
  git add data docs
  git commit -q -m "data: epoch $epoch" || echo "nothing to commit"
  echo "committed epoch $epoch"
fi

# Pushing is left to the operator or to an explicit push step: this script does
# not touch the remote on its own.
echo "=== cron run finished (epoch rc=$rc) ==="
exit "$rc"
