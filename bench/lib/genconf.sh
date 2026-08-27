# shellcheck shell=bash
# Emits a loadtest.conf for one epoch. Sourced by epoch.sh.
#
# The minter role alternates between alice and bob across epochs so that both
# nodes see the same aggregate workload over time. Without that, comparing
# alice (sqlite) to bob (postgres) would just be comparing a minter to a
# receiver.

# gen_conf <out_path> <minter_tapd> <minter_lnd> <peer_tapd> <peer_lnd>
gen_conf() {
  local out=$1 mt=$2 ml=$3 pt=$4 pl=$5

  cat > "$out" <<EOF
network=regtest

# test-case is deliberately unset: the runner selects one case per invocation
# with -test.run so each case gets its own clean timing.

mint-test-batch-size=$MINT_BATCH_SIZE
mint-test-total-groups=$MINT_TOTAL_GROUPS
mint-test-supply-min=$MINT_SUPPLY_MIN
mint-test-supply-max=$MINT_SUPPLY_MAX

send-test-num-sends=$SEND_NUM_SENDS
send-test-num-assets=$SEND_NUM_ASSETS
send-test-concurrency=$SEND_CONCURRENCY
send-test-mix=$SEND_MIX
send-asset-type="$SEND_ASSET_TYPE"
addr-version="$SEND_ADDR_VERSION"

burn-test-num-burns=$BURN_NUM_BURNS
burn-test-amount=$BURN_AMOUNT

sync-type="$SYNC_TYPE"
sync-num-clients=$SYNC_NUM_CLIENTS
sync-page-size=$SYNC_PAGE_SIZE

test-suite-timeout=$SUITE_TIMEOUT
test-timeout=$CASE_TIMEOUT

[bitcoin]
bitcoin.host="localhost"
bitcoin.port=18443
bitcoin.user=lightning
bitcoin.password=lightning

[alice]
alice.tapd.name=$mt
alice.tapd.host="localhost"
alice.tapd.port=${TAPD_GRPC[$mt]}
alice.tapd.restport=${TAPD_REST[$mt]}
alice.tapd.courierhost=$mt
alice.tapd.courierport=10029
alice.tapd.tlspath=$CREDS/$mt/tls.cert
alice.tapd.macpath=$CREDS/$mt/admin.macaroon
alice.lnd.name=$ml
alice.lnd.host="localhost"
alice.lnd.port=${LND_GRPC[$ml]}
alice.lnd.tlspath=$CREDS/$ml/tls.cert
alice.lnd.macpath=$CREDS/$ml/admin.macaroon

[bob]
bob.tapd.name=$pt
bob.tapd.host="localhost"
bob.tapd.port=${TAPD_GRPC[$pt]}
bob.tapd.restport=${TAPD_REST[$pt]}
bob.tapd.courierhost=$pt
bob.tapd.courierport=10029
bob.tapd.tlspath=$CREDS/$pt/tls.cert
bob.tapd.macpath=$CREDS/$pt/admin.macaroon
bob.lnd.name=$pl
bob.lnd.host="localhost"
bob.lnd.port=${LND_GRPC[$pl]}
bob.lnd.tlspath=$CREDS/$pl/tls.cert
bob.lnd.macpath=$CREDS/$pl/admin.macaroon

[prometheus-gateway]
prometheus-gateway.enabled=false
EOF
}
