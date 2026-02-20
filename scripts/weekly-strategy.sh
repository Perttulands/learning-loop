#!/usr/bin/env bash
# weekly-strategy.sh - Generate weekly strategy report from learning loop data
# Usage: SCORES_DIR=path FEEDBACK_DIR=path REPORTS_DIR=path ./scripts/weekly-strategy.sh
# Env: SCORES_DIR, FEEDBACK_DIR, REPORTS_DIR (defaults to project subdirs)
# Output: state/reports/strategy-YYYY-WNN.json + human-readable summary to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/state/reports}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0"
  echo "Generate weekly strategy report from learning loop data."
  echo ""
  echo "Env vars: SCORES_DIR, FEEDBACK_DIR, REPORTS_DIR"
  exit 0
fi

if [[ ! -d "$SCORES_DIR" ]]; then
  echo "Error: scores directory not found: $SCORES_DIR" >&2
  exit 1
fi

mkdir -p "$REPORTS_DIR"

TEMPLATE_SCORES="$SCORES_DIR/template-scores.json"
AGENT_SCORES="$SCORES_DIR/agent-scores.json"
REFINEMENT_LOG="$SCORES_DIR/refinement-log.json"
AB_TESTS_FILE="$SCORES_DIR/ab-tests.json"
REGISTRY_FILE="$FEEDBACK_DIR/pattern-registry.json"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
week_label="$(date -u +%Y-W%V)"
report_file="$REPORTS_DIR/strategy-${week_label}.json"

# Read input files (empty defaults for optional ones)
template_data='{"templates":[]}'
if [[ -f "$TEMPLATE_SCORES" ]]; then
  template_data="$(cat "$TEMPLATE_SCORES")"
fi

agent_data='{"agents":[]}'
if [[ -f "$AGENT_SCORES" ]]; then
  agent_data="$(cat "$AGENT_SCORES")"
fi

registry_data='{}'
if [[ -f "$REGISTRY_FILE" ]]; then
  registry_data="$(cat "$REGISTRY_FILE")"
fi

refinement_data='{"entries":[]}'
if [[ -f "$REFINEMENT_LOG" ]]; then
  refinement_data="$(cat "$REFINEMENT_LOG")"
fi

ab_data='{"tests":[]}'
if [[ -f "$AB_TESTS_FILE" ]]; then
  ab_data="$(cat "$AB_TESTS_FILE")"
fi

# Build the report with a single jq pipeline
report="$(jq -n \
  --arg ts "$ts" \
  --arg week "$week_label" \
  --argjson templates "$template_data" \
  --argjson agents "$agent_data" \
  --argjson registry "$registry_data" \
  --argjson refinements "$refinement_data" \
  --argjson ab "$ab_data" \
'
# Template trends: extract key fields from template-scores
def template_trends:
  [$templates.templates[] |
    {template, total_runs, score, full_pass_rate, trend, confidence}
  ] | sort_by(-.score);

# Agent comparison: extract from agent-scores
def agent_comparison:
  [$agents.agents[] |
    {agent, total_runs, pass_rate, score, avg_duration_ratio,
     top_pattern: (if (.top_failure_patterns | length) > 0 then .top_failure_patterns[0].pattern else null end)}
  ] | sort_by(-.score);

# Top 3 failure patterns from registry
def top_patterns:
  [$registry | to_entries[] | {pattern: .key, count: .value.count, last_seen: .value.last_seen}]
  | sort_by(-.count) | .[:3];

# A/B test results
def ab_results:
  {
    active_tests: [($ab.tests // [])[] | select(.status == "active") | {original, variant, original_runs, variant_runs, target_runs}],
    completed_this_week: [($ab.tests // [])[] | select(.status == "completed") | {original, variant, decision}]
  };

# Refinement activity from log
def refinement_activity:
  [($refinements.entries // [])[] | {
    template: (.template // .original),
    variant: .variant,
    type: (if .type == "ab_test_result" then "ab_result" else "refinement" end),
    trigger: (.trigger // .decision // null),
    timestamp
  }];

# System-level metrics for weekly snapshots
def metrics:
  ($templates.templates // []) as $t |
  {
    total_templates: ($t | length),
    total_runs: ([$t[].total_runs] | add // 0),
    scoreable_runs: ([$t[].scoreable_runs] | add // 0),
    avg_template_score: ([$t[].score] | if length > 0 then add / length else 0 end),
    overall_full_pass_rate:
      (if ([$t[].scoreable_runs] | add // 0) > 0 then
         (([$t[] | (.full_pass_rate * .scoreable_runs)] | add // 0) / ([$t[].scoreable_runs] | add))
       else 0 end),
    active_ab_tests: ([($ab.tests // [])[] | select(.status == "active")] | length),
    completed_ab_tests: ([($ab.tests // [])[] | select(.status == "completed")] | length),
    refinements_logged: ([($refinements.entries // [])[] | select(.trigger != null)] | length)
  };

# Generate recommendations based on data
def recommendations:
  [
    # Recommend focusing on low-scoring templates with enough data
    ($templates.templates | [.[] | select(.confidence != "low" and .score < 0.5)] |
      if length > 0 then
        "Refine underperforming templates: " + ([.[].template] | join(", "))
      else empty end),

    # Recommend investigating top failure pattern
    ([$registry | to_entries[] | {pattern: .key, count: .value.count}] | sort_by(-.count) |
      if length > 0 then
        "Address top failure pattern: " + .[0].pattern + " (" + (.[0].count | tostring) + " occurrences)"
      else empty end),

    # Agent performance gap
    ([$agents.agents[] | {agent, score}] | sort_by(-.score) |
      if length >= 2 then
        if (.[0].score - .[1].score) > 0.05 then
          "Agent performance gap: " + .[0].agent + " (" + (.[0].score * 100 | round / 100 | tostring) + ") vs " + .[1].agent + " (" + (.[1].score * 100 | round / 100 | tostring) + ")"
        else empty end
      else empty end)
  ];

# Short highlight list for human scanability
def highlights:
  (metrics) as $m |
  [
    "Templates tracked: " + ($m.total_templates | tostring) + ", total runs: " + ($m.total_runs | tostring),
    "Overall full-pass rate: " + (($m.overall_full_pass_rate * 100 | round) | tostring) + "%",
    "Average template score: " + (($m.avg_template_score * 100 | round / 100) | tostring),
    "A/B tests: " + ($m.active_ab_tests | tostring) + " active, " + ($m.completed_ab_tests | tostring) + " completed"
  ];

# Human-readable summary
def summary_text:
  ($templates.templates | length) as $tpl_count |
  ([$templates.templates[].total_runs] | if length > 0 then add else 0 end) as $total_runs |
  ([$templates.templates[] | select(.trend == "improving")] | length) as $improving |
  "Weekly Strategy Report (" + $week + "): " +
  ($total_runs | tostring) + " total runs across " + ($tpl_count | tostring) + " templates. " +
  ($improving | tostring) + " template(s) improving.";

{
  schema_version: "1.0.0",
  generated_at: $ts,
  week_ending: $week,
  template_trends: template_trends,
  agent_comparison: agent_comparison,
  top_failure_patterns: top_patterns,
  ab_results: ab_results,
  refinement_activity: refinement_activity,
  metrics: metrics,
  highlights: highlights,
  recommendations: recommendations,
  summary: summary_text
}
')"

# Write report
echo "$report" > "$report_file"

# Print human-readable summary to stdout
summary="$(echo "$report" | jq -r '.summary')"
echo "$summary"
echo "Report written to: $report_file"

# Notify: weekly report
"$SCRIPT_DIR/notify.sh" weekly-report --summary "$summary" 2>/dev/null || true # REASON: Weekly reporting should not fail if notifications are unavailable.
