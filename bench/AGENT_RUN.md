# What the scheduled run does

Deterministic work lives in the scripts. The scheduled agent run is the reporting
layer on top, so that a regression gets noticed rather than just recorded.

Per fire, in order:

1. `bench/deploy.sh` — no-op if the network is already up, recovers it after a
   host reboot. If it fails, stop and report; do not try to run an epoch.
2. `bench/epoch.sh` — one epoch. Exits non-zero if a case did not pass, but the
   record is written either way.
3. `bench/report.sh` — the comparison against the trailing baseline.
4. `bench/render.sh` — refresh `docs/`.
5. Commit `data/` and `docs/`. Push only if pushing is enabled for this schedule.

Then read the report and decide whether anything needs saying:

- **Case failed or skipped.** Read `logs/epoch-*/<case>.log`. Say what the error
  was, and whether it looks like a tapd problem or a harness problem. Do not
  "fix" it by removing the case from `CASES`.
- **SLOW flag.** A case more than 50% above its baseline. Check whether the
  storage numbers moved with it. A slow case with flat storage is a different
  animal from a slow case tracking a growing database.
- **RESTARTS flag.** The daemon crash-looped. This outranks everything else in
  the report: pull the container logs.
- **DIVERGED flag.** The two universe servers hold different content, so the
  backend comparison is invalid for that epoch. Check the federation with
  `tapcli universe federation list` on both.
- **Nothing flagged.** Say so in one line. Do not narrate the numbers that the
  site already shows.

Things not to do without being asked: change `bench/config.env` (it breaks
comparability with every prior epoch), reset the network, or bump the pinned tapd
version.
