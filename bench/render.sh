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
    # detail carries the measurements a native case took for itself. Only the
    # backup case sets it, so it is null everywhere else and the page has to
    # treat it as optional.
    cases: [.cases[] | {name, status, duration_s, detail: (.detail // null)}],
    after: {
      tapd: (.after.tapd | map_values({
        backend, db_bytes, proofs_bytes, assets, universe_roots,
        backup_bytes: (.backup_bytes // null),
        universe_leaves: (.universe_leaves // 0),
        multiverse_root: (.multiverse_root // "")
      })),
      containers: ((.after.containers // {}) | map_values({
        mem_bytes, mem_peak_bytes: (.mem_peak_bytes // 0)
      }))
    },
    delta: (.delta | map_values({db_bytes})),
    # Delta sync and cold start. Only the fields the page plots, and each is
    # optional: epochs recorded before these were collected carry neither, and
    # the page has to render those as gaps rather than as zeros.
    delta_sync: ((.delta_sync // {}) | map_values({
      rounds, total_s, max_s, cursor_advance, universes_synced, fallbacks
    })),
    startup: ((.startup // {}) | map_values({ready_s}))
  } ] | sort_by(.epoch)' "$DATA" > "$OUT/epochs.json"

# Symbolize the captured pprof profiles into JSON. Needs the Go toolchain and a
# copy of the tapd binary the profiles came from; skipped cleanly without either,
# so a machine that only renders the site still works.
if command -v go >/dev/null 2>&1 && [[ -f "$ROOT/bench/bin/tapd-symbols" ]]; then
  python3 "$ROOT/bench/symbolize.py" "$ROOT" "$ROOT/bench/bin/tapd-symbols" \
    "$OUT/profiles.json" || echo "symbolize failed (continuing)"
  # The same profiles, reduced to one verdict per operation. This is the view
  # meant to be read first; profiles.json is the drill-down behind it.
  python3 "$ROOT/bench/bottleneck.py" "$ROOT" "$ROOT/bench/bin/tapd-symbols" \
    "$OUT/bottlenecks.json" || echo "bottleneck pass failed (continuing)"
else
  echo "skipping profile symbolization (no go toolchain or no symbol binary)"
fi

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
