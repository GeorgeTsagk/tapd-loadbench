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
  ($all[:-1] | .[-$w:]) as $base |

  # Most metrics here grow monotonically by design: the universe gets bigger
  # every epoch, so a sync is meant to take longer than it did last time.
  # Comparing against the mean of the window would therefore flag every single
  # epoch forever. What matters is departure from the established trend, so the
  # prediction is the last reading plus the average per-epoch increment.
  def series($name): [$base[] | .cases[] | select(.name == $name)
                      | select(.status == "pass") | .duration_s];
  def trend($s): if ($s | length) < 2 then null
                 else (($s | last) - ($s | first)) / (($s | length) - 1) end;
  def predict($s): if ($s | length) < 2 then null
                   else ($s | last) + trend($s) end;
  def r2($v): if $v == null then "n/a" else ($v * 100 | round / 100 | tostring) end;
  def mb($b): (($b / 1048576) * 100 | round / 100 | tostring) + " MB";

  "epoch \($cur.epoch)  tapd \($cur.versions.tapd)  minter \($cur.roles.minter)",
  "baseline: \($base | length) prior epochs",
  "",
  "cases (measured against the trend, not the mean, because these grow by design):",
  ( $cur.cases[] as $c
    | series($c.name) as $s
    | "  \($c.name): \($c.status) \($c.duration_s)s" +
      (if ($s | length) == 0 then ""
       elif ($s | length) < 2 then "  (prev \(($s | last))s)"
       else "  (prev \(($s | last))s, trend \(r2(trend($s)))s/epoch, " +
            "predicted \(r2(predict($s)))s)" end)
  ),
  "",
  "storage:",
  ( $cur.after.tapd | keys[] as $n
    | "  \($n) (\($cur.after.tapd[$n].backend)): db \(mb($cur.after.tapd[$n].db_bytes))" +
      "  proofs \(mb($cur.after.tapd[$n].proofs_bytes))" +
      "  assets \($cur.after.tapd[$n].assets)" +
      "  universe leaves \($cur.after.tapd[$n].universe_leaves // 0) (lagging aggregate)" +
      "  this epoch +\($cur.delta[$n].db_bytes)B db, +\($cur.delta[$n].proofs_bytes)B proofs"
  ),
  "",
  "flags:",
  ( [ ( $cur.cases[] | select(.status != "pass")
        | "  CASE \(.name) did not pass: \(.status)" ),
      ( $cur.after.tapd | to_entries[]
        | select(.value.container.restart_count > 0)
        | "  RESTARTS \(.key) has restarted \(.value.container.restart_count) time(s)" ),
      # Slow means "well above where the trend said it would land", with an
      # absolute floor so a 2s case does not trip on sub-second jitter.
      ( $cur.cases[] as $c
        | series($c.name) as $s
        | select(($s | length) >= 4)
        | predict($s) as $p
        | select($c.status == "pass" and $c.duration_s > ($p * 1.4)
                 and ($c.duration_s - $p) > 3)
        | "  SLOW \($c.name) took \($c.duration_s)s, trend predicted \(r2($p))s" ),
      # The same test in the other direction: a metric that grows every epoch
      # and then suddenly stops is usually a case silently doing no work.
      ( $cur.cases[] as $c
        | series($c.name) as $s
        | select(($s | length) >= 4)
        | select(trend($s) > 0.5)
        | predict($s) as $p
        | select($c.status == "pass" and $c.duration_s < ($p * 0.5))
        | "  STALLED \($c.name) took \($c.duration_s)s, well under the predicted \(r2($p))s - check it did real work" ),
      ( $cur.after.tapd | to_entries[]
        | select(.value.goroutines > 1000)
        | "  GOROUTINES \(.key) at \(.value.goroutines)" ),
      # The backend comparison is only meaningful while the two universe servers
      # hold the same content.
      ( ($cur.after.tapd["uni-tapd"].multiverse_root // "") as $r1
        | ($cur.after.tapd["uni2-tapd"].multiverse_root // "") as $r2
        | select($r1 != "" and $r2 != "" and $r1 != $r2)
        | "  DIVERGED universe servers hold different state: " +
          "uni-tapd root \($r1[0:12]), uni2-tapd root \($r2[0:12]) " +
          "- the backend comparison is not valid for this epoch" )
    ] | if length == 0 then "  none" else .[] end
  )
' "$DATA"
