# tapd load benchmark

A persistent Taproot Assets regtest network that never gets reset, plus a cron job
that runs one load epoch against it and appends the numbers to
[`data/epochs.jsonl`](data/epochs.jsonl).

The question this answers is not "how fast is tapd". CI already measures that on
a clean node. It is **how tapd behaves as its state grows**: after a few hundred
epochs the asset store, the proof archive and the universe hold real volume, and
the interesting number is what epoch 300 costs compared to epoch 1.

## Network

Eight containers, brought up by [`bench/deploy.sh`](bench/deploy.sh) and defined
in `.ddp/` (generated with the `ddp` skill). Volumes are never removed, so state
survives restarts and host reboots.

| Node | Role | DB backend | gRPC | Prometheus |
|---|---|---|---|---|
| `alice-tapd` | minter | sqlite | 10029 | 8989 |
| `bob-tapd` | receiver | postgres | 10030 | 8990 |
| `uni-tapd` | universe server, proof courier | sqlite | 10031 | 8991 |
| `uni2-tapd` | universe server, postgres twin of `uni-tapd` | postgres | 10032 | 8992 |
| `alice`, `bob`, `uni`, `uni2` | lnd v0.21.2-beta, one per tapd | n/a | 10011-10014 | n/a |
| `bitcoind` | Bitcoin Core 29, regtest | n/a | 18443 | n/a |
| `pg` | PostgreSQL 16, holds `bobtapd` and `uni2tapd` | n/a | 5432 | n/a |

tapd is pinned to **v0.8.1**. Pinning is deliberate: with the version fixed, any
movement in the time series is attributable to accumulated state rather than to a
code change. Bumping the pin is a deliberate act that should be called out in the
commit, because it breaks comparability across the bump.

### Where the backend comparison lives

The minter is fixed, not alternating. The send case calls the taproot-assets itest
helper `SyncUniverses`, which polls until the two nodes' universe root sets are
*equal*, and that only holds while one of them has no assets of its own. With both
nodes minting the sets diverge permanently and the case spins to its timeout. The
assertion is in the vendored taproot-assets package, so it cannot be relaxed from
the load suite.

That means `alice-tapd` (sqlite) is always the minter and `bob-tapd` (postgres)
always the receiver, so those two are **not** a backend comparison. They are two
different jobs. The sqlite-vs-postgres comparison is made instead between
`uni-tapd` and `uni2-tapd`: federation peers that both sync all assets, so they
hold the same content under the same sync load and differ only in backend. Every
epoch record carries both nodes' root counts, and `bench/report.sh` and the site
both flag any epoch where their multiverse root hashes disagree, because the
comparison is meaningless when they do. The root hash commits to a node's whole
universe, so equal hashes mean equal content.

Note that the universe servers hold fewer roots than the minter: the minter also
tracks roots for its own issuance. What has to match for the comparison to hold is
the two universe servers against each other, which is what the check tests.

Expect the first handful of epochs to show a wild postgres-to-sqlite ratio. At
these volumes postgres is dominated by 8 kB page and extent allocation, not by the
data. The ratio is only worth reading once the series is long.

Both universe servers are also brought into the federation explicitly by
`bench/deploy.sh` rather than by the `--universe.federationserver` flag alone:
tapd only honours that flag if the peer is already accepting RPC at startup, and
compose start order does not guarantee it. A node that silently ends up with an
empty federation stops receiving proofs, which would quietly corrupt every later
number, so `deploy.sh` reconciles the topology and hard-fails if it cannot.

## One epoch

[`bench/epoch.sh`](bench/epoch.sh) runs three load cases, times each one
separately, and writes a single JSON record:

| Case | What it does |
|---|---|
| `mintV2` | tops the minter's group set up to `MINT_TOTAL_GROUPS`, then mints a `MINT_BATCH_SIZE` batch into one of its own groups |
| `sendV2` | `SEND_NUM_SENDS` transfers, direction drawn at random each iteration, over v2 addresses |
| `sync` | `SYNC_NUM_CLIENTS` fresh clients each perform a full universe sync |

Tunables live in [`bench/config.env`](bench/config.env). Changing one breaks
comparability with earlier epochs, so bump `SCHEMA_NOTE` when you do.

The load generator is the suite that was removed from taproot-assets in commit
`1cf127aa` ("itest: remove loadtest subdirectory") and extracted into a separate
repository, which is not public. [`bench/build.sh`](bench/build.sh) builds it from
a checkout you point it at, so **regenerating the binary needs access to that
repository**. Everything else here works without it: the harness, the recorded
data and the site depend only on a built binary being present at
`bench/bin/loadtest`. The exact revision each epoch ran against is recorded in
`bench/bin/loadtest.rev`.

### Cases that are not run

`mint`, `send` and `multisig` are excluded. They reuse taproot-assets `itest`
assertion helpers that assert on global counts, such as `AssertAddrEvent`
requiring exactly one address event. That holds only on a node that was just
created. On a network that is never reset those counts grow every epoch, so
these cases fail from epoch 2 onward for reasons that say nothing about tapd. The
V2 cases exist precisely because they assert less. `multisig` is worse than merely
failing: it mints a group with a different decimal display, which used to wedge
`mintV2` permanently.

Three fixes to the load suite came out of setting this up, held on a branch of
that repository:

- the multisig case handed its own host-side address to the peer as the universe
  host, so the peer dialled itself and tapd rejected the self-add
- `mintV2` drew its target group from the assets held by *both* nodes, but a
  group's internal key lives only in the keyring of the node that minted the
  anchor, so a swapped minter failed with `can't sign with group key`
- the same group set was unfiltered by decimal display, so one foreign group
  permanently broke minting

## Metrics

Per epoch, before and after, for each of the three tapd nodes:

- `db_bytes`: tapd's own `total_db_size` gauge. Backend-aware, so sqlite and
  postgres numbers come from the same code path and are comparable. Note that
  postgres includes a fixed multi-megabyte catalog baseline: **compare growth
  rates, not absolute sizes.**
- `storage`: backend detail. For sqlite the main file, WAL, SHM and migration
  backups separately; the main file is often tiny while the WAL holds everything
  not yet checkpointed, which is why `db_bytes` rather than the file size is the
  headline. For postgres, `pg_database_size` plus the ten largest relations.
- `proofs_bytes`, `proofs_files`: the on-disk proof archive, which lives outside
  the database and is otherwise invisible.
- `assets`, `groups`, `universe_roots`, `universe_leaves`, `multiverse_sum`,
  `mint_batches`: state counts from tapcli. `universe_leaves` is the proof count
  from `universe stats`. Read it as an indicator only: tapd aggregates those stats
  in the background, so the figure lags, sometimes by several epochs. When an exact
  answer matters, use `multiverse_root`.
- `heap_bytes`, `goroutines`, `grpc_calls`: from the tapd Prometheus endpoint.
- `container.restart_count`: a rising count means the daemon is crash-looping,
  which would otherwise hide behind passing cases.

`delta` in each record is the per-epoch growth, which is the number that compares
across epochs.

The universe stats gauges (`num_assets_minted`, `num_total_groups`,
`num_total_proofs`) are aggregated in the background by tapd and lag behind
reality, so the authoritative counts here come from tapcli, not from Prometheus.

## Running it

```sh
bench/build.sh            # build the load generator
bench/deploy.sh           # bring the network up, bootstrap if fresh (idempotent)
bench/epoch.sh            # run one epoch, append to data/epochs.jsonl
bench/render.sh           # refresh the site under docs/
```

`bench/deploy.sh --reset` destroys all state and starts over. It prompts first.

Nothing here is specific to one machine except the container runtime: `.ddp/`
holds the compose definition and is not committed, because it is generated and
machine-local. `bench/lib/common.sh` is the single place the topology, ports and
backends are declared.

`bench/epoch.sh` takes a lock and exits quietly if an epoch is already running, so
overlapping cron fires skip rather than interleave. A failed case still gets
recorded, because a failed epoch is data, and then the script exits non-zero.

## Profiling

`alice-tapd` and `bob-tapd` run a locally built image: pinned v0.8.1 plus a single
added import, `_ "net/http/pprof"`. Without it tapd accepts `--profile`, starts an
HTTP listener, and serves nothing: the listener has only a catch-all redirect to
`/debug/pprof`, which nothing handles, so every request bounces to itself. The
patched binary reports `commit=v0.8.1-dirty`, so profiled epochs identify
themselves in `versions.tapd`. Rebuild with `bench/build-pprof-image.sh`.

Each case is bracketed by a capture, so profiles attribute to one operation
rather than to the epoch as a whole. That matters because `alloc_space` is
cumulative since the process started: a single end-of-epoch snapshot mixes every
case across every epoch since the last restart. The difference across a bracket is
what that case allocated, and the heap difference is what it left behind. A
further capture at the epoch boundary is what cross-epoch diffs compare.

Profiles are stored as protobuf in `logs/epoch-NNNNN/pprof/` so `go tool pprof
-base` stays available: 42 files and about 8 MB per epoch. Measured cost: about 6 ms of stop-the-world per epoch against a 220 s
epoch, and roughly 45 KB per epoch on disk. Heap sampling itself was already
running, since `MemProfileRate` defaults to one sample per 512 KB.

`bench/symbolize.py` turns the newest profiles into `docs/profiles.json` for the
site, and diffs them against the oldest on disk for the growth view. Symbol names
survive the release build's `-s -w` because Go keeps its own `pclntab`, so no
special build is needed.

### Attribution

Dependency frames are folded onto the nearest owned caller rather than filtered
out. Filtering them looks tempting, since third-party code is not yours to change,
but it discards the signal: 16 MiB sitting in `btcd/wire.scriptFreeList.Borrow` is
really `proof.TxDecoder` and `lndclient.unmarshallTransaction` deserializing
transactions a lot, which is a fact about tapd. `pprof -show` folds it to the
caller and keeps that.

Whatever has no owned caller at all cannot be folded, so it is reported as an
explicit unattributed figure instead of vanishing. On the minter that is around
17% of live heap: grpc handler chains, `runtime.allocm` (which tracks OS threads
and so tracks the goroutine count), and `pgregory.net/rapid`, a property-testing
library that is linked into the release binary.

The page offers both views, folded and raw by leaf function.

The node page browses all of it: node, operation, profile type, attribution and
grouping by function or by package, with a filter and sortable columns. Grouping
by package is the subsystem view, since tapd sets no pprof labels and package
paths are the closest thing to a named subsystem.

`--prometheus.perfhistograms` is also on, which adds per-method gRPC latency
histograms; each epoch records calls, total time and mean per method.

## Site

[`docs/`](docs/) is a static page over `data/epochs.jsonl`, no build step. The raw
JSON is served next to it so the numbers stay inspectable.
