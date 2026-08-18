#!/usr/bin/env bash
# Cron entry point. Brings the network up if a reboot took it down, runs one
# epoch, refreshes the site, and commits. Designed to be safe to fire on a
# schedule with no one watching.
#
# Install with:
#   crontab -l 2>/dev/null | { cat; echo "23 */6 * * * $PWD/bench/cron.sh"; } | crontab -
set -uo pipefail

# cron gives a minimal environment. Everything this script shells out to has to
# be on PATH explicitly, and git needs HOME to find the credential store.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin:$HOME/go/bin"
# cron may not export HOME, and git needs it to find the credential store.
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

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

"$HERE/report.sh" > "$ROOT/logs/report-$STAMP.txt" 2>&1 || true
cat "$ROOT/logs/report-$STAMP.txt"

"$HERE/render.sh" || echo "render failed (continuing)"

cd "$ROOT"
if [[ -n "$(git status --porcelain data docs 2>/dev/null)" ]]; then
  epoch=$(wc -l < data/epochs.jsonl)
  git add data docs
  git commit -q -m "data: epoch $epoch" || echo "nothing to commit"
  echo "committed epoch $epoch"
fi

# Push so the published page tracks the data. Never force, and never let a push
# failure lose the local commit: the record is already safe in the log.
if git remote get-url origin >/dev/null 2>&1; then
  git push origin HEAD || echo "push failed (commit is local, will go with the next run)"
fi

echo "=== cron run finished (epoch rc=$rc) ==="
exit "$rc"
