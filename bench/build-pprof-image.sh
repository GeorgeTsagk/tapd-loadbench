#!/usr/bin/env bash
# Build the tapd image the asset nodes run: the pinned release plus the one
# import that makes --profile serve anything.
#
# tapd accepts --profile and starts an HTTP listener, but never imports
# net/http/pprof, so the listener has only a catch-all redirect to /debug/pprof
# and every request bounces to itself. Adding the import is the whole patch.
#
# The build otherwise mirrors the published image: same Go minor, make
# release-install so the monitoring tag is present and prometheus keeps working,
# and curl in the final image so profiles can be pulled over docker exec without
# publishing a port. Symbol stripping in the release ldflags does not matter:
# Go keeps its own pclntab, so go tool pprof still resolves function names.
set -euo pipefail

TAG="${TAPD_TAG:-v0.8.1}"
SRC="${TAPD_SRC:-/workspace/tapd-v081-pprof}"
IMAGE="${IMAGE:-tapd-v081-pprof:local}"
GO_IMAGE="${GO_IMAGE:-golang:1.25.10-alpine}"

if [[ ! -d "$SRC" ]]; then
  git clone --depth 1 --branch "$TAG" \
    https://github.com/lightninglabs/taproot-assets.git "$SRC"
fi

cd "$SRC"
if ! grep -q 'net/http/pprof' cmd/tapd/main.go; then
  python3 - <<'PY'
p = "cmd/tapd/main.go"
s = open(p).read()
old = '\t"net/http"\n\t"os"\n'
new = ('\t"net/http"\n'
       '\t// Registers the /debug/pprof handlers on http.DefaultServeMux, which\n'
       '\t// is the mux the --profile listener serves. Without this the listener\n'
       '\t// has only the catch-all redirect and every path bounces to itself.\n'
       '\t_ "net/http/pprof"\n'
       '\t"os"\n')
assert old in s, "import block not where expected"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "patched cmd/tapd/main.go"
fi

cat > Dockerfile.pprof <<EOF
FROM $GO_IMAGE AS builder
ENV CGO_ENABLED=0
RUN apk add --no-cache --update make git gcc musl-dev
COPY . /app
WORKDIR /app
RUN make release-install

FROM alpine AS final
VOLUME /root/.tapd
RUN apk --no-cache add bash jq ca-certificates curl
COPY --from=builder /go/bin/tapd /bin/
COPY --from=builder /go/bin/tapcli /bin/
EXPOSE 10029 8089
ENTRYPOINT ["tapd"]
EOF

docker build -q -t "$IMAGE" -f Dockerfile.pprof .
docker run --rm --entrypoint sh "$IMAGE" -c 'tapd --version'
