#!/usr/bin/env bash
# Print a compact regression report for the most recent epoch: how it compares to
# the trailing baseline, and anything that looks off.
#
# This exists so the per-run reporting step reads a few lines of conclusions
# rather than the whole history.
#
# Usage: bench/report.sh [baseline_window]   (default 10 epochs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/data/epochs.jsonl"
WINDOW="${1:-10}"

[[ -s "$DATA" ]] || { echo "no epochs recorded yet"; exit 0; }

jq -s --argjson w "$WINDOW" -r '
  sort_by(.epoch) as $all |
  ($all | last) as $cur |
  # Baseline is the window of epochs before this one, same-parity excluded:
  # roles alternate, so a like-for-like comparison uses every prior epoch and
  # relies on the window being wide enough to cover both roles.
  ($all[:-1] | .[-$w:]) as $base |

  def avg(f): if ($base | length) == 0 then null
              else ($base | map(f) | add / length) end;
  def pct($now; $then): if $then == null or $then == 0 then null
              else (($now - $then) / $then * 100) end;
  def fmtpct($v): if $v == null then "n/a"
              else (if $v >= 0 then "+" else "" end) + ($v | .*10 | round / 10 | tostring) + "%" end;
  def mb($b): (($b / 1048576) * 100 | round / 100 | tostring) + " MB";

  "epoch \($cur.epoch)  tapd \($cur.versions.tapd)  minter \($cur.roles.minter)",
  "baseline: \($base | length) prior epochs",
  "",
  "cases:",
  ( $cur.cases[] as $c
    | ($base | map(.cases[] | select(.name == $c.name) | select(.status == "pass") | .duration_s)) as $hist
    | (if ($hist | length) > 0 then ($hist | add / length) else null end) as $mean
    | "  \($c.name): \($c.status) \($c.duration_s)s" +
      (if $mean == null then ""
       else "  (baseline \(($mean * 100 | round) / 100)s, \(fmtpct(pct($c.duration_s; $mean))))" end)
  ),
  "",
  "storage:",
  ( $cur.after.tapd | keys[] as $n
    | "  \($n) (\($cur.after.tapd[$n].backend)): db \(mb($cur.after.tapd[$n].db_bytes))" +
      "  proofs \(mb($cur.after.tapd[$n].proofs_bytes))" +
      "  assets \($cur.after.tapd[$n].assets)" +
      "  this epoch +\($cur.delta[$n].db_bytes)B db, +\($cur.delta[$n].proofs_bytes)B proofs"
  ),
  "",
  "flags:",
  ( [ ( $cur.cases[] | select(.status != "pass")
        | "  CASE \(.name) did not pass: \(.status)" ),
      ( $cur.after.tapd | to_entries[]
        | select(.value.container.restart_count > 0)
        | "  RESTARTS \(.key) has restarted \(.value.container.restart_count) time(s)" ),
      ( $cur.cases[] as $c
        | ($base | map(.cases[] | select(.name == $c.name) | select(.status == "pass") | .duration_s)) as $hist
        | select(($hist | length) >= 3)
        | ($hist | add / length) as $mean
        | select($c.status == "pass" and $c.duration_s > $mean * 1.5)
        | "  SLOW \($c.name) took \($c.duration_s)s vs baseline \(($mean * 100 | round) / 100)s" ),
      ( $cur.after.tapd | to_entries[]
        | select(.value.goroutines > 1000)
        | "  GOROUTINES \(.key) at \(.value.goroutines)" ),
      # The sqlite/postgres comparison is only meaningful while the two
      # universe servers hold the same content. Say so when they do not.
      ( select($cur.after.tapd["uni-tapd"].universe_roots
               != $cur.after.tapd["uni2-tapd"].universe_roots)
        | "  DIVERGED universe servers hold different content: " +
          "uni-tapd \($cur.after.tapd["uni-tapd"].universe_roots) roots, " +
          "uni2-tapd \($cur.after.tapd["uni2-tapd"].universe_roots) roots " +
          "- the backend comparison is not valid for this epoch" )
    ] | if length == 0 then "  none" else .[] end
  )
' "$DATA"
