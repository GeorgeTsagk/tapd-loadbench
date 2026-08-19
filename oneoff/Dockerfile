# One-off image for benchmarking taproot-assets PR #2202 (cursor-based delta
# sync). Mirrors the official release build: same make target, so the monitoring
# build tag is present and the prometheus endpoint works. Go version follows the
# PR branch go.mod (1.26), which is newer than v0.8.1 shipped with; that is a
# confounder for memory comparisons but the measurement here is delta sync
# against enumeration sync on this same binary.
FROM golang:1.26-alpine AS builder
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
