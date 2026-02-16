#!/usr/bin/env bash
# Tests for weekly-strategy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/weekly-strategy.sh"

PASS=0
FAIL=0
TOTAL=0

assert() {
  local desc="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
  fi
}

# Setup temp dirs
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCORES_DIR="$TMPDIR_BASE/scores"
FEEDBACK_DIR="$TMPDIR_BASE/feedback"
REPORTS_DIR="$TMPDIR_BASE/reports"
mkdir -p "$SCORES_DIR" "$FEEDBACK_DIR" "$REPORTS_DIR"

# Helper: create template-scores.json
create_template_scores() {
  local file="$SCORES_DIR/template-scores.json"
  cat > "$file" <<'TMPL'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-16T06:34:18Z",
  "templates": [
    {
      "template": "custom",
      "total_runs": 85,
      "scoreable_runs": 75,
      "full_pass_rate": 0.35,
      "partial_pass_rate": 0.60,
      "retry_rate": 0.22,
      "timeout_rate": 0.01,
      "score": 0.55,
      "confidence": "high",
      "trend": "improving",
      "agents": [
        {"agent": "claude", "total_runs": 46, "full_pass_rate": 0.42, "score": 0.58},
        {"agent": "codex", "total_runs": 39, "full_pass_rate": 0.23, "score": 0.50}
      ]
    },
    {
      "template": "bug-fix",
      "total_runs": 8,
      "scoreable_runs": 7,
      "full_pass_rate": 0.57,
      "partial_pass_rate": 0.29,
      "retry_rate": 0.12,
      "timeout_rate": 0.0,
      "score": 0.66,
      "confidence": "medium",
      "trend": "stable",
      "agents": [
        {"agent": "claude", "total_runs": 8, "full_pass_rate": 0.57, "score": 0.66}
      ]
    }
  ]
}
TMPL
}

# Helper: create agent-scores.json
create_agent_scores() {
  local file="$SCORES_DIR/agent-scores.json"
  cat > "$file" <<'AGT'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-16T06:34:18Z",
  "agents": [
    {
      "agent": "claude",
      "total_runs": 51,
      "pass_rate": 0.42,
      "score": 0.57,
      "avg_duration_ratio": 0.74,
      "top_failure_patterns": [
        {"pattern": "verification-gap", "count": 28},
        {"pattern": "test-failure-after-completion", "count": 21},
        {"pattern": "repeated-failure", "count": 15}
      ],
      "templates": [
        {"template": "custom", "total_runs": 46, "score": 0.58, "full_pass_rate": 0.42}
      ]
    },
    {
      "agent": "codex",
      "total_runs": 39,
      "pass_rate": 0.23,
      "score": 0.50,
      "avg_duration_ratio": 0.57,
      "top_failure_patterns": [
        {"pattern": "verification-gap", "count": 16},
        {"pattern": "repeated-failure", "count": 24}
      ],
      "templates": [
        {"template": "custom", "total_runs": 39, "score": 0.50, "full_pass_rate": 0.23}
      ]
    }
  ]
}
AGT
}

# Helper: create pattern-registry.json
create_registry() {
  local file="$FEEDBACK_DIR/pattern-registry.json"
  cat > "$file" <<'REG'
{
  "verification-gap": {
    "count": 44,
    "first_seen": "2026-02-09T06:00:00Z",
    "last_seen": "2026-02-16T06:34:18Z",
    "last_beads": ["bd-4sf", "bd-6wq", "bd-94w"]
  },
  "test-failure-after-completion": {
    "count": 37,
    "first_seen": "2026-02-09T06:00:00Z",
    "last_seen": "2026-02-16T06:34:18Z",
    "last_beads": ["bd-3kl", "bd-3o5"]
  },
  "repeated-failure": {
    "count": 39,
    "first_seen": "2026-02-10T06:00:00Z",
    "last_seen": "2026-02-16T06:34:18Z",
    "last_beads": ["bd-x79"]
  }
}
REG
}

# Helper: create refinement-log.json
create_refinement_log() {
  local file="$SCORES_DIR/refinement-log.json"
  cat > "$file" <<'REFLOG'
{
  "schema_version": "1.0.0",
  "entries": [
    {
      "template": "custom",
      "variant": "custom-v1",
      "trigger": "low_pass_rate",
      "timestamp": "2026-02-14T03:00:00Z",
      "full_pass_rate": 0.35,
      "total_runs": 85,
      "patterns_applied": ["verification-gap", "test-failure-after-completion"]
    },
    {
      "type": "ab_test_result",
      "original": "custom",
      "variant": "custom-v1",
      "decision": "promoted",
      "original_score": 0.55,
      "variant_score": 0.68,
      "timestamp": "2026-02-15T12:00:00Z"
    }
  ]
}
REFLOG
}

# Helper: create ab-tests.json
create_ab_tests() {
  local file="$SCORES_DIR/ab-tests.json"
  cat > "$file" <<'AB'
{
  "schema_version": "1.0.0",
  "tests": [
    {
      "original": "bug-fix",
      "variant": "bug-fix-v1",
      "status": "active",
      "target_runs": 10,
      "original_runs": 5,
      "variant_runs": 4,
      "created_at": "2026-02-15T00:00:00Z"
    }
  ]
}
AB
}

# === Script existence and basics ===

assert "weekly-strategy.sh exists" '[[ -f "$SCRIPT" ]]'
assert "weekly-strategy.sh is executable" '[[ -x "$SCRIPT" ]]'

# Usage message
output="$("$SCRIPT" --help 2>&1 || true)"
assert "shows usage with --help" '[[ "$output" == *"Usage"* || "$output" == *"usage"* ]]'

# === Empty/missing data ===

output="$(SCORES_DIR="$TMPDIR_BASE/nonexistent" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT" 2>&1 || true)"
assert "handles missing scores dir" '[[ "$output" == *"not found"* || "$output" == *"Error"* || "$output" == *"error"* ]]'

# === Basic report generation ===

create_template_scores
create_agent_scores
create_registry

output="$(SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT" 2>&1)"
assert "produces output on success" '[[ -n "$output" ]]'

# Check report file was created with date-based name
shopt -s nullglob
report_files=("$REPORTS_DIR"/strategy-*.json)
shopt -u nullglob
assert "creates report file" '[[ ${#report_files[@]} -gt 0 ]]'

# === Report content (JSON format) ===

report="${report_files[0]}"

assert "report has schema_version" 'jq -e ".schema_version" "$report" >/dev/null 2>&1'
assert "report has generated_at" 'jq -e ".generated_at" "$report" >/dev/null 2>&1'
assert "report has week_ending" 'jq -e ".week_ending" "$report" >/dev/null 2>&1'

# Template trends section
assert "report has template_trends" 'jq -e ".template_trends" "$report" >/dev/null 2>&1'
assert "template_trends is array" '[[ "$(jq ".template_trends | type" "$report")" == "\"array\"" ]]'
assert "template_trends has custom" 'jq -e ".template_trends[] | select(.template == \"custom\")" "$report" >/dev/null 2>&1'
assert "template entry has score" 'jq -e ".template_trends[0].score" "$report" >/dev/null 2>&1'
assert "template entry has trend" 'jq -e ".template_trends[0].trend" "$report" >/dev/null 2>&1'
assert "template entry has total_runs" 'jq -e ".template_trends[0].total_runs" "$report" >/dev/null 2>&1'

# Agent comparison section
assert "report has agent_comparison" 'jq -e ".agent_comparison" "$report" >/dev/null 2>&1'
assert "agent_comparison is array" '[[ "$(jq ".agent_comparison | type" "$report")" == "\"array\"" ]]'
assert "agent_comparison has claude" 'jq -e ".agent_comparison[] | select(.agent == \"claude\")" "$report" >/dev/null 2>&1'
assert "agent entry has pass_rate" 'jq -e ".agent_comparison[0].pass_rate" "$report" >/dev/null 2>&1'
assert "agent entry has score" 'jq -e ".agent_comparison[0].score" "$report" >/dev/null 2>&1'

# Top failure patterns section
assert "report has top_failure_patterns" 'jq -e ".top_failure_patterns" "$report" >/dev/null 2>&1'
assert "top_failure_patterns is array" '[[ "$(jq ".top_failure_patterns | type" "$report")" == "\"array\"" ]]'
assert "top_failure_patterns has top 3" '[[ "$(jq ".top_failure_patterns | length" "$report")" -le 3 ]]'
assert "pattern entry has name and count" 'jq -e ".top_failure_patterns[0].pattern" "$report" >/dev/null 2>&1 && jq -e ".top_failure_patterns[0].count" "$report" >/dev/null 2>&1'

# Recommendations section
assert "report has recommendations" 'jq -e ".recommendations" "$report" >/dev/null 2>&1'
assert "recommendations is array" '[[ "$(jq ".recommendations | type" "$report")" == "\"array\"" ]]'

# Summary section
assert "report has summary" 'jq -e ".summary" "$report" >/dev/null 2>&1'
assert "summary is string" '[[ "$(jq ".summary | type" "$report")" == "\"string\"" ]]'

# === With refinement log and A/B tests ===

rm -rf "$REPORTS_DIR"/*
create_refinement_log
create_ab_tests

output="$(SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT" 2>&1)"

shopt -s nullglob
report_files=("$REPORTS_DIR"/strategy-*.json)
shopt -u nullglob
report="${report_files[0]}"

# A/B results section
assert "report has ab_results" 'jq -e ".ab_results" "$report" >/dev/null 2>&1'
assert "ab_results has active tests" 'jq -e ".ab_results.active_tests" "$report" >/dev/null 2>&1'
assert "ab_results active_tests count" '[[ "$(jq ".ab_results.active_tests | length" "$report")" -eq 1 ]]'
assert "ab_results has completed" 'jq -e ".ab_results.completed_this_week" "$report" >/dev/null 2>&1'

# Refinement activity
assert "report has refinement_activity" 'jq -e ".refinement_activity" "$report" >/dev/null 2>&1'
assert "refinement_activity has entries" '[[ "$(jq ".refinement_activity | length" "$report")" -gt 0 ]]'

# === Report file naming ===

filename="$(basename "$report")"
assert "filename contains strategy" '[[ "$filename" == strategy-* ]]'
assert "filename has date format" '[[ "$filename" =~ strategy-[0-9]{4}-W[0-9]{2}\.json ]]'

# === Summary output to stdout ===

assert "stdout includes summary text" '[[ "$output" == *"Weekly"* || "$output" == *"weekly"* || "$output" == *"Strategy"* || "$output" == *"strategy"* ]]'

# --- Results ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
