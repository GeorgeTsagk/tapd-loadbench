#!/usr/bin/env bash
# Bring the persistent tapbench network up and bootstrap it if it is fresh.
# Idempotent: safe to run against an already-running network, and safe to run
# after a host reboot. Never wipes state unless --reset is passed.
#
# Usage: bench/deploy.sh [--reset]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"

RESET=0
[[ "${1:-}" == "--reset" ]] && RESET=1

if (( RESET )); then
  echo "WARNING: destroying all network state (volumes, assets, epoch history)"
  read -r -p "type 'reset' to confirm: " ans
  [[ "$ans" == "reset" ]] || die "aborted"
  $COMPOSE down -v
fi

# Phase 1: the two services everything else depends on. bob-tapd will not start
# until its database exists, so postgres must be up and seeded first.
log "starting bitcoind and postgres"
$COMPOSE up -d bitcoind pg

log "waiting for postgres"
for _ in $(seq 1 60); do
  docker exec pg pg_isready -U lightning >/dev/null 2>&1 && break; sleep 1
done
docker exec pg pg_isready -U lightning >/dev/null || die "postgres never came up"

for db in $PG_DATABASES; do
  if ! docker exec pg psql -U lightning -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    log "creating database $db"
    docker exec pg psql -U lightning -d postgres -c "CREATE DATABASE \"$db\""
  fi
done

log "waiting for bitcoind"
for _ in $(seq 1 60); do btc getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done
btc getblockchaininfo >/dev/null || die "bitcoind never came up"

# bitcoind is started with -wallet pointing at a path that does not exist on a
# fresh volume, so the wallet has to be created once.
btc listwallets | jq -e 'index("miner")' >/dev/null 2>&1 \
  || { log "creating miner wallet"; btc createwallet miner >/dev/null; }

# Coinbase outputs need 100 confirmations before they are spendable.
height=$(btc getblockcount)
if (( height < 101 )); then
  log "mining $((101 - height)) blocks to maturity"
  mine $((101 - height))
fi

# lnd reports synced_to_chain false when the best block is old, and tapd waits
# for lnd to be synced before it will start. On regtest nothing advances the
# chain except an epoch, so a gap in the schedule makes the whole stack
# unstartable until someone mines. Keep the tip fresh.
tip_age=$(( $(date +%s) - $(btc getblockchaininfo | jq -r .mediantime) ))
if (( tip_age > 1800 )); then
  log "chain tip is $((tip_age / 60))m old, mining to refresh it"
  mine 1
fi

log "starting remaining nodes"
$COMPOSE up -d

log "waiting for lnd"
for n in $LND_NODES; do
  for _ in $(seq 1 90); do lncli "$n" getinfo >/dev/null 2>&1 && break; sleep 2; done
  lncli "$n" getinfo >/dev/null || die "$n never came up"
done

log "waiting for tapd"
for n in $TAPD_NODES; do
  for _ in $(seq 1 90); do tapcli "$n" getinfo >/dev/null 2>&1 && break; sleep 2; done
  tapcli "$n" getinfo >/dev/null || die "$n never came up"
done

for n in $LND_NODES; do ensure_funded "$n" "$MIN_LND_BALANCE"; done

log "connecting peers"
for pair in "alice bob" "alice uni" "bob uni" "alice uni2" "uni uni2"; do
  set -- $pair
  pk=$(lncli "$2" getinfo | jq -r .identity_pubkey)
  lncli "$1" connect "$pk@$2:9735" >/dev/null 2>&1 || true
done

log "reconciling universe federation"
ensure_federation

sync_creds
health_check

echo
echo "network ready"
for n in $TAPD_NODES; do
  printf '  %-11s %-9s grpc localhost:%-6s prom localhost:%s\n' \
    "$n" "(${TAPD_DB[$n]})" "${TAPD_GRPC[$n]}" "${TAPD_PROM[$n]}"
done
echo "  block height $(btc getblockcount)"
