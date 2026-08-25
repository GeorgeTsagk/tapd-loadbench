#!/usr/bin/env bash
# Build the tapd image the asset nodes run: a pinned tapd revision plus the
# small patch that makes runtime profiling reachable.
#
# Three things are patched, all of them absent upstream as of main @ 9cbf40a6:
#
#   1. net/http/pprof is never imported, so --profile starts a listener whose
#      only route is a catch-all redirect to /debug/pprof and every request
#      bounces to itself. The import is the whole fix.
#   2. Block profiling is off in the Go runtime by default and tapd has no
#      config for it, so goroutine blocking time is unmeasurable.
#   3. Mutex profiling is likewise off with no config.
#
# The two rates are read from the environment rather than hardcoded, so the
# same binary runs with profiling on or off. That is what lets the harness
# A/B its own overhead instead of assuming it is small.
#
# The build otherwise mirrors the published image: CGO_ENABLED=0 with the
# monitoring tag via make release-install, so prometheus keeps working, and
# curl in the final image so profiles can be pulled over docker exec without
# publishing a port. Symbol stripping in the release ldflags does not matter,
# Go keeps its own pclntab, so go tool pprof still resolves function names.
set -euo pipefail

REV="${TAPD_REV:?set TAPD_REV to the commit to build}"
SRC="${TAPD_SRC:-/workspace/tapd-main-pprof}"
IMAGE="${IMAGE:-tapd-main-pprof:local}"
UPSTREAM="${TAPD_UPSTREAM:-/workspace/taproot-assets}"

export PATH=$PATH:/usr/local/go/bin
export GOTOOLCHAIN=auto

if [[ ! -d "$SRC/.git" ]]; then
  git clone "$UPSTREAM" "$SRC"
fi

cd "$SRC"
git fetch -q "$UPSTREAM" main
git checkout -q --detach "$REV"
git clean -qfd
BUILT_REV=$(git rev-parse --short HEAD)

python3 - <<'PY'
import re

path = "cmd/tapd/main.go"
src = open(path).read()

# 1+2+3: the imports the patch needs. net/http/pprof registers its handlers on
# http.DefaultServeMux, which is the mux the --profile listener serves.
old_imports = '''	"fmt"
	"net/http"
	"os"
	"runtime/pprof"
	"strings"
'''
new_imports = '''	"fmt"
	"net/http"
	_ "net/http/pprof"
	"os"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
'''
if '_ "net/http/pprof"' not in src:
    assert old_imports in src, "import block not where expected"
    src = src.replace(old_imports, new_imports, 1)

# The rate hook goes immediately before the profile listener, so profiling
# configuration is all in one place.
anchor = '\tif cfg.Profile != "" {\n'
hook = '''	// Block and mutex profiling are off by default in the Go runtime and
	// tapd exposes no config for either, so goroutine blocking time and
	// lock contention cannot be measured at all. Read both rates from the
	// environment: that keeps one binary usable with profiling on and off,
	// which is what lets a harness measure the cost of its own profiling
	// rather than assume it is negligible.
	if v := os.Getenv("TAPD_BLOCK_PROFILE_RATE"); v != "" {
		if rate, err := strconv.Atoi(v); err == nil {
			runtime.SetBlockProfileRate(rate)
			cfgLogger.Infof("Block profile rate set to %v ns", rate)
		}
	}
	if v := os.Getenv("TAPD_MUTEX_PROFILE_FRACTION"); v != "" {
		if frac, err := strconv.Atoi(v); err == nil {
			runtime.SetMutexProfileFraction(frac)
			cfgLogger.Infof("Mutex profile fraction set to %v", frac)
		}
	}

'''
if "TAPD_BLOCK_PROFILE_RATE" not in src:
    assert anchor in src, "profile listener block not where expected"
    src = src.replace(anchor, hook + anchor, 1)

# 4. A start/stop CPU profile pair. The stock net/http/pprof handler only
# offers ?seconds=N, which cannot be bracketed to an operation: the window
# has to be guessed in advance, so it either truncates the operation or runs
# past it into the next one. Explicit start and stop give each operation its
# own exact window with no padding. seconds= on start is a watchdog, so a
# harness that dies mid-operation cannot leave the profiler running.
cpu_handlers = '''	// Start and stop handlers for CPU profiling, which the stock
	// net/http/pprof only exposes as a fixed ?seconds=N window. A window
	// chosen in advance cannot line up with an operation whose duration is
	// not known until it ends, so per-operation CPU attribution needs an
	// explicit bracket. The seconds parameter on start is a watchdog that
	// stops the profile if the caller never comes back.
	if cfg.Profile != "" {
		var (
			cpuMu   sync.Mutex
			cpuFile *os.File
			cpuStop *time.Timer
		)
		stopLocked := func() {
			if cpuFile == nil {
				return
			}
			pprof.StopCPUProfile()
			if cpuStop != nil {
				cpuStop.Stop()
				cpuStop = nil
			}
		}
		http.HandleFunc(
			"/debug/cpu/start",
			func(w http.ResponseWriter, r *http.Request) {
				cpuMu.Lock()
				defer cpuMu.Unlock()
				if cpuFile != nil {
					http.Error(w, "already profiling", 409)
					return
				}
				f, err := os.CreateTemp("", "tapd-cpu-*.pb.gz")
				if err != nil {
					http.Error(w, err.Error(), 500)
					return
				}
				if err := pprof.StartCPUProfile(f); err != nil {
					_ = f.Close()
					_ = os.Remove(f.Name())
					http.Error(w, err.Error(), 500)
					return
				}
				cpuFile = f
				watchdog := 30 * time.Minute
				if v := r.URL.Query().Get("seconds"); v != "" {
					if n, err := strconv.Atoi(v); err == nil {
						watchdog = time.Duration(n) *
							time.Second
					}
				}
				cpuStop = time.AfterFunc(watchdog, func() {
					cpuMu.Lock()
					defer cpuMu.Unlock()
					stopLocked()
				})
				fmt.Fprintln(w, "started")
			},
		)
		http.HandleFunc(
			"/debug/cpu/stop",
			func(w http.ResponseWriter, r *http.Request) {
				cpuMu.Lock()
				f := cpuFile
				stopLocked()
				cpuFile = nil
				cpuMu.Unlock()
				if f == nil {
					http.Error(w, "not profiling", 409)
					return
				}
				name := f.Name()
				_ = f.Close()
				defer func() { _ = os.Remove(name) }()
				http.ServeFile(w, r, name)
			},
		)
	}

'''
if "/debug/cpu/start" not in src:
    src = src.replace(anchor, cpu_handlers + anchor, 1)
    src = src.replace(
        '\t"strconv"\n\t"strings"\n',
        '\t"strconv"\n\t"strings"\n\t"sync"\n\t"time"\n', 1,
    )

open(path, "w").write(src)
print("patched cmd/tapd/main.go")
PY

gofmt -l cmd/tapd/main.go && echo "gofmt clean"

STAGE="$SRC/.build-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
GOBIN="$STAGE" make release-install

cat > Dockerfile.pprof <<EOF
FROM alpine AS final
VOLUME /root/.tapd
RUN apk --no-cache add bash jq ca-certificates curl
COPY .build-stage/tapd /bin/
COPY .build-stage/tapcli /bin/
EXPOSE 10029 8089
ENTRYPOINT ["tapd"]
EOF

docker build -q -t "$IMAGE" -f Dockerfile.pprof .
echo "built $IMAGE from $BUILT_REV"
docker run --rm --entrypoint sh "$IMAGE" -c 'tapd --version'
