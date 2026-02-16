#!/usr/bin/env bash
# score-templates.sh - Aggregate feedback records into template and agent scores
# Usage: FEEDBACK_DIR=path SCORES_DIR=path ./scripts/score-templates.sh
# Env: FEEDBACK_DIR (default: state/feedback/), SCORES_DIR (default: state/scores/)
# Outputs: template-scores.json + agent-scores.json
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
  # No feedback files - write empty results
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$ts" \
    '{schema_version: "1.0.0", generated_at: $ts, templates: []}' \
    > "$SCORES_DIR/template-scores.json"
  jq -n --arg ts "$ts" \
    '{schema_version: "1.0.0", generated_at: $ts, agents: []}' \
    > "$SCORES_DIR/agent-scores.json"
  exit 0
fi

# Merge all feedback records into one array (filter out non-feedback files like pattern-registry.json)
all_feedback="$(jq -s '[.[] | select(.bead != null)]' "${feedback_files[@]}")"

# Single jq pipeline produces both template-scores and agent-scores
combined="$(echo "$all_feedback" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
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
    (records | sort_by(.bead)) as $sorted |
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

def top_patterns(records; n):
  [records[] | .failure_patterns // [] | .[]] |
  group_by(.) |
  [.[] | {pattern: .[0], count: length}] |
  sort_by(-.count) |
  .[:n];

def avg_duration(records):
  [records[] | .signals.duration_ratio // 0] |
  if length == 0 then 0 else add / length end;

{
  template_scores: {
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
  },
  agent_scores: {
    schema_version: "1.0.0",
    generated_at: $ts,
    agents: [
      group_by(.agent)[] |
      (.[0].agent) as $agent_name |
      (. | length) as $total |
      compute_score(.) as $scores |
      {
        agent: $agent_name,
        total_runs: $total,
        pass_rate: $scores.full_pass_rate,
        score: $scores.score,
        avg_duration_ratio: avg_duration(.),
        top_failure_patterns: top_patterns(.; 5),
        templates: [
          group_by(.template)[] |
          (.[0].template) as $tpl |
          compute_score(.) as $tpl_scores |
          {
            template: $tpl,
            total_runs: length,
            score: $tpl_scores.score,
            full_pass_rate: $tpl_scores.full_pass_rate
          }
        ]
      }
    ]
  }
}
')"

# Detect score regressions before overwriting
new_scores="$(echo "$combined" | jq '.template_scores')"
if [[ -f "$SCORES_DIR/template-scores.json" ]]; then
  old_scores="$(cat "$SCORES_DIR/template-scores.json")"
  # Compare scores: alert if any template drops by > 0.1 (with >= 10 runs)
  regressions="$(jq -n --argjson old "$old_scores" --argjson new "$new_scores" '
    [($new.templates // [])[] | select(.total_runs >= 10) |
      .template as $t | .score as $ns |
      ([$old.templates[] | select(.template == $t)] | if length > 0 then .[0].score else null end) as $os |
      select($os != null and ($os - $ns) > 0.1) |
      {template: $t, old_score: $os, new_score: $ns}
    ]')"

  reg_count="$(echo "$regressions" | jq 'length')"
  if [[ "$reg_count" -gt 0 ]]; then
    i=0
    while [[ $i -lt $reg_count ]]; do
      tpl="$(echo "$regressions" | jq -r ".[$i].template")"
      os="$(echo "$regressions" | jq -r ".[$i].old_score")"
      ns="$(echo "$regressions" | jq -r ".[$i].new_score")"
      "$SCRIPT_DIR/notify.sh" score-regression \
        --template "$tpl" --old-score "$os" --new-score "$ns" 2>/dev/null || true
      i=$((i + 1))
    done
  fi
fi

# Split combined output into two files
echo "$new_scores" > "$SCORES_DIR/template-scores.json"
echo "$combined" | jq '.agent_scores' > "$SCORES_DIR/agent-scores.json"
