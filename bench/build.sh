#!/usr/bin/env bash
# Build the load generator.
#
# The load suite was extracted out of taproot-assets in commit 1cf127aa ("itest:
# remove loadtest subdirectory") into a separate repository that is not public.
# Building therefore needs access to it, and its location has to be supplied:
#
#   LOADTEST_SRC=/path/to/checkout        bench/build.sh
#   LOADTEST_GIT_URL=git@host:org/repo    bench/build.sh
#
# Everything else in this repository works without it. Only regenerating the
# binary needs the source.
set -euo pipefail
export PATH="$PATH:/usr/local/go/bin:${HOME}/go/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LOADTEST_SRC:-}"

if [[ -z "$SRC" ]]; then
  if [[ -n "${LOADTEST_GIT_URL:-}" ]]; then
    SRC="$(mktemp -d)/loadtest"
    echo "cloning load suite into $SRC"
    git clone "$LOADTEST_GIT_URL" "$SRC"
  else
    echo "error: set LOADTEST_SRC to a checkout of the load suite, or" >&2
    echo "       LOADTEST_GIT_URL to clone it. See the comment in this file." >&2
    exit 1
  fi
fi

[[ -d "$SRC" ]] || { echo "error: $SRC is not a directory" >&2; exit 1; }

mkdir -p "$HERE/bin"
git -C "$SRC" rev-parse --short HEAD > "$HERE/bin/loadtest.rev"
( cd "$SRC" && make loadtest )
cp "$SRC/loadtest" "$HERE/bin/loadtest"
echo "built $(cat "$HERE/bin/loadtest.rev") -> $HERE/bin/loadtest"
