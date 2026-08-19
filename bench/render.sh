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

# docs/ is the Pages publish root, so docs/CNAME is what binds the custom domain.
# Nothing here deletes it, but losing it silently unbinds the domain, so fail
# loudly rather than publishing a site that reverts to the github.io URL.
if [[ -f "$OUT/CNAME" ]]; then
  grep -qE '^[a-z0-9.-]+$' "$OUT/CNAME" || { echo "docs/CNAME looks malformed" >&2; exit 1; }
fi

mkdir -p "$OUT"

# The page reads a small subset of each record. Project just that: the full
# records stay in data/epochs.jsonl, while the page payload stays small no
# matter how long the series gets.
jq -s '[ .[] | {
    epoch, finished_at, duration_s,
    versions: {tapd: .versions.tapd, lnd: .versions.lnd},
    cases: [.cases[] | {name, status, duration_s}],
    after: {
      tapd: (.after.tapd | map_values({
        backend, db_bytes, proofs_bytes, assets, universe_roots,
        universe_leaves: (.universe_leaves // 0),
        multiverse_root: (.multiverse_root // "")
      })),
      containers: ((.after.containers // {}) | map_values({
        mem_bytes, mem_peak_bytes: (.mem_peak_bytes // 0)
      }))
    },
    delta: (.delta | map_values({db_bytes}))
  } ] | sort_by(.epoch)' "$DATA" > "$OUT/epochs.json"

# The detail page shares the series page styling. Generate the stylesheet from
# index.html rather than keeping a second copy that can drift.
python3 - "$OUT" <<'CSSEOF'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
src = (out / "index.html").read_text()
css = src[src.index("<style>") + len("<style>"):src.index("</style>")].strip()
(out / "tokens.css").write_text(
    "/* Generated from index.html by bench/render.sh. Do not edit. */\n" + css + "\n"
)
CSSEOF

# The node detail page needs every field of the most recent epoch, which the
# projected series above deliberately drops. Keep it in its own small file rather
# than widening the series payload for one page.
jq -s 'sort_by(.epoch) | last' "$DATA" > "$OUT/latest.json"

# Fragment for a single-page host that supplies its own document wrapper (the
# Artifact tool): keep <title> first so it is found, drop the outer tags, and
# define the data before the main script so it never attempts a fetch.
python3 - "$OUT" <<'PYEOF'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
page = (out / "index.html").read_text()
head = page[page.index("<title>"):page.index("</head>")]
body = page[page.index("<body>") + len("<body>"):page.index("</body>")]
data = (out / "epochs.json").read_text().strip()
(out / "artifact.html").write_text(
    head
    + "<script>window.__EPOCHS__=" + data + ";</script>\n"
    # The artifact publishes one page, so a relative link to the detail page
    # would 404 there. Keep the words, drop the anchor.
    + body.replace('<a href="nodes.html">node snapshot</a>', 'node snapshot')
)
PYEOF

echo "wrote $OUT/latest.json (epoch $(jq -r .epoch "$OUT/latest.json"))"
echo "wrote $OUT/epochs.json ($(jq 'length' "$OUT/epochs.json") epochs, $(du -h "$OUT/epochs.json" | cut -f1))"
echo "wrote $OUT/artifact.html ($(du -h "$OUT/artifact.html" | cut -f1))"
