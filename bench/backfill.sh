#!/usr/bin/env bash
# Run many epochs back to back to front-load history.
#
# Deliberately does not touch bench/config.env: epochs produced here have to be
# comparable with the ones already recorded, and every available way to make an
# epoch faster changes what the epoch measures.
#
# Usage: bench/backfill.sh <count> [commit_every]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COUNT="${1:?usage: backfill.sh <count> [commit_every]}"
EVERY="${2:-10}"

# Stop rather than grind through hours of failing epochs. A few consecutive
# failures means something is wrong that more epochs will not fix.
MAX_CONSECUTIVE_FAILURES=3

cd "$ROOT"
start=$(date +%s)
done_n=0 failed=0 consecutive=0

publish() {
  "$HERE/render.sh" >/dev/null || return 0
  if [[ -n "$(git status --porcelain data docs)" ]]; then
    git add data docs
    git commit -q -m "data: epochs through $(wc -l < data/epochs.jsonl)"
    git push -q origin HEAD 2>/dev/null \
      || echo "  push failed, commit is local"
  fi
}

echo "backfill: $COUNT epochs, publishing every $EVERY, from epoch $(( $(wc -l < data/epochs.jsonl) + 1 ))"

for i in $(seq 1 "$COUNT"); do
  n=$(( $(wc -l < data/epochs.jsonl) + 1 ))
  if "$HERE/epoch.sh" >/dev/null 2>&1; then
    consecutive=0
  else
    failed=$(( failed + 1 )); consecutive=$(( consecutive + 1 ))
    echo "  epoch $n FAILED (consecutive: $consecutive)"
    if (( consecutive >= MAX_CONSECUTIVE_FAILURES )); then
      echo "backfill: aborting after $consecutive consecutive failures"
      publish
      exit 1
    fi
  fi
  done_n=$(( done_n + 1 ))

  elapsed=$(( $(date +%s) - start ))
  # Epochs get slower as state grows, so a flat average understates the
  # remaining time. Good enough to see whether it is on track.
  avg=$(( elapsed / done_n ))
  left=$(( (COUNT - done_n) * avg ))
  printf '  %d/%d done  epoch %d  elapsed %dm  avg %ds  rough eta %dm\n' \
    "$done_n" "$COUNT" "$n" $(( elapsed / 60 )) "$avg" $(( left / 60 ))

  (( done_n % EVERY == 0 )) && publish
done

publish
echo "backfill: finished $done_n epochs, $failed failed, $(( ($(date +%s) - start) / 60 ))m total"
