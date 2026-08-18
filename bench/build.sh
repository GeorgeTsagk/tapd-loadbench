#!/usr/bin/env bash
# Build the load generator. Its source lives in the separate private repo
# the extracted load suite, which was extracted out of taproot-assets in
# commit 1cf127aa ("itest: remove loadtest subdirectory").
set -euo pipefail
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LOADTEST_SRC:-${LOADTEST_SRC}}"

[[ -d "$SRC" ]] || {
  echo "cloning load suite into $SRC"
  git clone "$LOADTEST_GIT_URL" "$SRC"
}

git -C "$SRC" rev-parse --short HEAD > "$HERE/bin/loadtest.rev"
( cd "$SRC" && make loadtest )
cp "$SRC/loadtest" "$HERE/bin/loadtest"
echo "built $(cat "$HERE/bin/loadtest.rev") -> $HERE/bin/loadtest"
