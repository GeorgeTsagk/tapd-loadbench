#!/usr/bin/env bash
# Render data/epochs.jsonl into the static site under docs/.
#
# The site is plain HTML plus the raw JSONL: no build step, no dependencies, and
# the underlying data stays inspectable rather than only existing as pixels.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DATA="$ROOT/data/epochs.jsonl"
OUT="$ROOT/docs"

[[ -s "$DATA" ]] || { echo "no data yet at $DATA"; exit 0; }

mkdir -p "$OUT"

# The page fetches this, so it has to sit next to index.html.
jq -c '.' "$DATA" | jq -s '.' > "$OUT/epochs.json"

jq -s -r '
  (map(select(.cases | all(.status == "pass"))) | length) as $ok |
  length as $n |
  last as $l |
  "generated \(now | strftime("%Y-%m-%d %H:%M UTC")) · \($n) epochs · \($ok) fully green · tapd \($l.versions.tapd)"
' "$DATA" > "$OUT/summary.txt"

echo "wrote $OUT/epochs.json ($(jq 'length' "$OUT/epochs.json") epochs)"
