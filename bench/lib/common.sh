# shellcheck shell=bash
# Shared helpers. Source, do not execute.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DDP="$REPO_ROOT/.ddp"
COMPOSE="docker compose -f $DDP/docker-compose.yml -p tapbench"
CREDS="$REPO_ROOT/bench/creds"
BTC="docker exec bitcoind bitcoin-cli -regtest -rpcuser=lightning -rpcpassword=lightning"

TAPD_NODES="alice-tapd bob-tapd uni-tapd uni2-tapd"
LND_NODES="alice bob uni uni2"

# Host-side gRPC ports (must match .ddp/network.json).
declare -A TAPD_GRPC=( [alice-tapd]=10029 [bob-tapd]=10030 [uni-tapd]=10031 [uni2-tapd]=10032 )
declare -A TAPD_REST=( [alice-tapd]=8089  [bob-tapd]=8090  [uni-tapd]=8091  [uni2-tapd]=8092 )
declare -A TAPD_PROM=( [alice-tapd]=8989  [bob-tapd]=8990  [uni-tapd]=8991  [uni2-tapd]=8992 )
declare -A LND_GRPC=(  [alice]=10011      [bob]=10012      [uni]=10013      [uni2]=10014 )

# Which db backend each tapd runs, and for the postgres ones which database.
# uni-tapd and uni2-tapd are the like-for-like pair: same federation content,
# same sync load, different backend.
declare -A TAPD_DB=( [alice-tapd]=sqlite [bob-tapd]=postgres
                     [uni-tapd]=sqlite   [uni2-tapd]=postgres )
declare -A TAPD_PGDB=( [bob-tapd]=bobtapd [uni2-tapd]=uni2tapd )
PG_DATABASES="bobtapd uni2tapd"

# Federation topology. tapd only honours --universe.federationserver if the peer
# is already accepting RPC when tapd starts, and compose start order does not
# guarantee that, so deploy.sh reconciles this explicitly instead.
declare -A FEDERATION=(
  [alice-tapd]="uni-tapd uni2-tapd"
  [bob-tapd]="uni-tapd uni2-tapd"
  [uni-tapd]="uni2-tapd"
  [uni2-tapd]="uni-tapd"
)

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

btc()  { $BTC "$@"; }
lncli()  { local n=$1; shift; docker exec "$n" lncli --network regtest "$@"; }
tapcli() { local n=$1; shift; docker exec "$n" tapcli --network regtest "$@"; }

# Mine N blocks to the bitcoind miner wallet.
mine() {
  local n=${1:-6}
  local addr; addr=$($BTC -rpcwallet=miner getnewaddress)
  $BTC generatetoaddress "$n" "$addr" >/dev/null
}

# Copy TLS certs and macaroons out of the containers. Certs are regenerated
# when a container's IP changes, so refresh every epoch.
sync_creds() {
  local n
  for n in $LND_NODES; do
    mkdir -p "$CREDS/$n"
    docker cp "$n:/root/.lnd/tls.cert" "$CREDS/$n/tls.cert" >/dev/null
    docker cp "$n:/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon" \
      "$CREDS/$n/admin.macaroon" >/dev/null
  done
  for n in $TAPD_NODES; do
    mkdir -p "$CREDS/$n"
    docker cp "$n:/root/.tapd/tls.cert" "$CREDS/$n/tls.cert" >/dev/null
    docker cp "$n:/root/.tapd/data/regtest/admin.macaroon" \
      "$CREDS/$n/admin.macaroon" >/dev/null
  done
}

# Fail unless every container is running and every daemon answers an RPC.
health_check() {
  local n missing=""
  for n in bitcoind pg $LND_NODES $TAPD_NODES; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" == "true" ]] \
      || missing="$missing $n"
  done
  [[ -z "$missing" ]] || die "containers not running:$missing"

  $BTC getblockcount >/dev/null || die "bitcoind unresponsive"
  docker exec pg pg_isready -U lightning >/dev/null || die "postgres unresponsive"
  for n in $LND_NODES;  do lncli  "$n" getinfo >/dev/null || die "$n unresponsive"; done
  for n in $TAPD_NODES; do tapcli "$n" getinfo >/dev/null || die "$n unresponsive"; done
}

# Top up an lnd wallet if it is below the floor. Minting anchors assets on
# chain, so a minter that runs dry silently turns into a failed epoch.
ensure_funded() {
  local node=$1 floor=$2
  local bal; bal=$(lncli "$node" walletbalance | jq -r .confirmed_balance)
  if (( bal < floor )); then
    log "funding $node (balance $bal < $floor)"
    local addr; addr=$(lncli "$node" newaddress p2wkh | jq -r .address)
    $BTC -rpcwallet=miner sendtoaddress "$addr" 5 >/dev/null
    mine 6
    sleep 5
  fi
}

# Scrape a tapd prometheus endpoint once and cache it.
#
# Every scrape re-runs every collector, which for these nodes means a db-size
# query and an enumeration of every asset. Fetching the page once per node per
# snapshot instead of once per metric cuts that work by a factor of seven, and the
# handler only allows one request in flight anyway.
declare -A PROM_CACHE=()

prom_fetch() {
  local node=$1 body="" try
  for try in 1 2 3; do
    body=$(curl -s --max-time 60 "localhost:${TAPD_PROM[$node]}/metrics" 2>/dev/null)
    [[ -n "$body" ]] && break
    sleep 2
  done
  PROM_CACHE[$node]="$body"
  [[ -n "$body" ]] || log "  WARNING: prometheus scrape of $node returned nothing"
}

# Read one gauge or counter out of the cached scrape, summing label series.
#
# Prints nothing when the metric is absent, rather than 0. A failed scrape used to
# be recorded as zero, which does not read as missing data: it reads as an empty
# database, and it silently corrupted the series twice.
prom() {
  local node=$1 metric=$2
  [[ -n "${PROM_CACHE[$node]:-}" ]] || prom_fetch "$node"
  printf '%s' "${PROM_CACHE[$node]}" | awk -v m="$metric" '
    $1 == m || index($1, m "{") == 1 { s += $NF; f = 1 }
    END { if (f) print s }'
}

# Same value, or null when it could not be read, for embedding in JSON.
prom_json() {
  local v
  v=$(prom "$1" "$2")
  [[ -n "$v" ]] && printf '%s' "$v" || printf 'null'
}
