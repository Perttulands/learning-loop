#!/usr/bin/env bash
# score-templates.sh - Aggregate feedback records into template scores
# Usage: FEEDBACK_DIR=path SCORES_DIR=path ./scripts/score-templates.sh
# Env: FEEDBACK_DIR (default: state/feedback/), SCORES_DIR (default: state/scores/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"

if [[ ! -d "$FEEDBACK_DIR" ]]; then
  echo "Usage: FEEDBACK_DIR=<dir> SCORES_DIR=<dir> $0" >&2
  echo "Error: feedback directory not found: $FEEDBACK_DIR" >&2
  exit 1
fi

mkdir -p "$SCORES_DIR"

# Collect all feedback files into a single JSON array
shopt -s nullglob
feedback_files=("$FEEDBACK_DIR"/*.json)
shopt -u nullglob
if [[ ${#feedback_files[@]} -eq 0 ]]; then
  # No feedback files - write empty result
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version: "1.0.0", generated_at: $ts, templates: []}' \
    > "$SCORES_DIR/template-scores.json"
  exit 0
fi

# Merge all feedback records into one array
all_feedback="$(jq -s '.' "${feedback_files[@]}")"

# Process with jq: group by template, compute scores
echo "$all_feedback" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
def confidence(n): if n >= 20 then "high" elif n >= 5 then "medium" else "low" end;

def clamp(lo; hi): if . < lo then lo elif . > hi then hi else . end;

def compute_score(records):
  (records | length) as $total |
  ([records[] | select(.outcome != "infra_failure")] | length) as $scoreable |
  if $scoreable == 0 then
    {score: 0, full_pass_rate: 0, partial_pass_rate: 0, retry_rate: 0, timeout_rate: 0, scoreable_runs: 0}
  else
    ([records[] | select(.outcome == "full_pass")] | length) as $fp |
    ([records[] | select(.outcome == "partial_pass")] | length) as $pp |
    ([records[] | select(.outcome == "timeout")] | length) as $to |
    ([records[] | select(.signals.retried == true)] | length) as $retried |
    ($fp / $scoreable) as $fp_rate |
    ($pp / $scoreable) as $pp_rate |
    ($retried / $total) as $retry_rate |
    ($to / $scoreable) as $to_rate |
    (($fp_rate * 1.0) + ($pp_rate * 0.4) - ($retry_rate * 0.2) - ($to_rate * 0.3) | clamp(0; 1)) as $score |
    {score: $score, full_pass_rate: $fp_rate, partial_pass_rate: $pp_rate,
     retry_rate: $retry_rate, timeout_rate: $to_rate, scoreable_runs: $scoreable}
  end;

def compute_trend(records):
  (records | length) as $total |
  if $total < 10 then "insufficient_data"
  else
    # Sort by bead name (alphabetical proxy for chronological)
    (records | sort_by(.bead)) as $sorted |
    ($sorted | length) as $n |
    ($sorted[-10:]) as $last10 |
    ([$sorted[] | select(.outcome != "infra_failure")] | length) as $all_scoreable |
    ([$last10[] | select(.outcome != "infra_failure")] | length) as $l10_scoreable |
    if $all_scoreable == 0 or $l10_scoreable == 0 then "stable"
    else
      ([$sorted[] | select(.outcome == "full_pass")] | length / $all_scoreable) as $all_fp_rate |
      ([$last10[] | select(.outcome == "full_pass")] | length / $l10_scoreable) as $l10_fp_rate |
      ($l10_fp_rate - $all_fp_rate) as $delta |
      if $delta > 0.05 then "improving"
      elif $delta < -0.05 then "declining"
      else "stable"
      end
    end
  end;

def agent_breakdown(records):
  [records | group_by(.agent)[] |
    (.[0].agent) as $agent_name |
    compute_score(.) as $scores |
    {agent: $agent_name, total_runs: (. | length),
     full_pass_rate: $scores.full_pass_rate, score: $scores.score}
  ];

# Main pipeline
{
  schema_version: "1.0.0",
  generated_at: $ts,
  templates: [
    group_by(.template)[] |
    (.[0].template) as $tpl |
    (. | length) as $total |
    compute_score(.) as $scores |
    {
      template: $tpl,
      total_runs: $total,
      scoreable_runs: $scores.scoreable_runs,
      full_pass_rate: $scores.full_pass_rate,
      partial_pass_rate: $scores.partial_pass_rate,
      retry_rate: $scores.retry_rate,
      timeout_rate: $scores.timeout_rate,
      score: $scores.score,
      confidence: confidence($total),
      trend: compute_trend(.),
      agents: agent_breakdown(.)
    }
  ]
}
' > "$SCORES_DIR/template-scores.json"
