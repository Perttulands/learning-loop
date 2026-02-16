#!/usr/bin/env bash
# Tests for score-templates.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCORE_SCRIPT="$PROJECT_DIR/scripts/score-templates.sh"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_near() {
  local desc="$1" expected="$2" actual="$3" tolerance="${4:-0.01}"
  TOTAL=$((TOTAL + 1))
  local diff
  diff="$(echo "$expected - $actual" | bc -l | tr -d '-')"
  if (( $(echo "$diff <= $tolerance" | bc -l) )); then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: $expected (±$tolerance)"
    echo "  actual:   $actual"
  fi
}

# Setup temp dirs
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FEEDBACK_DIR="$TMPDIR_TEST/feedback"
SCORES_DIR="$TMPDIR_TEST/scores"
mkdir -p "$FEEDBACK_DIR" "$SCORES_DIR"

# Helper: create a feedback record
make_feedback() {
  local bead="$1" template="$2" agent="$3" outcome="$4" retried="${5:-false}"
  cat > "$FEEDBACK_DIR/$bead.json" <<EOF
{
  "schema_version": "1.0.0",
  "bead": "$bead",
  "timestamp": "2026-02-16T10:00:00Z",
  "template": "$template",
  "agent": "$agent",
  "model": "claude-sonnet-4-5-20250929",
  "outcome": "$outcome",
  "signals": {
    "exit_clean": true,
    "tests_pass": true,
    "lint_pass": true,
    "ubs_clean": true,
    "truthsayer_clean": true,
    "duration_ratio": 0.5,
    "retried": $retried
  },
  "failure_patterns": [],
  "prompt_hash": "abc123"
}
EOF
}

# --- Test: usage message when dir missing ---
output="$(FEEDBACK_DIR="/nonexistent/dir" "$SCORE_SCRIPT" 2>&1 || true)"
assert_eq "shows usage when dir missing" "0" "$([[ "$output" == *"Usage"* ]] && echo 0 || echo 1)"

# --- Test: empty feedback dir produces empty output ---
EMPTY_DIR="$TMPDIR_TEST/empty_feedback"
mkdir -p "$EMPTY_DIR"
FEEDBACK_DIR="$EMPTY_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
assert_eq "empty feedback produces empty templates" "0" "$(jq '.templates | length' "$SCORES_DIR/template-scores.json")"

# --- Test: single template, all full_pass ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-fp$i" "bug-fix" "claude" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"

assert_eq "output file exists" "true" "$([[ -f "$RESULT" ]] && echo true || echo false)"
assert_eq "valid JSON" "0" "$(jq empty "$RESULT" 2>&1 | wc -l)"
assert_eq "has schema_version" "1.0.0" "$(jq -r '.schema_version' "$RESULT")"
assert_eq "has generated_at" "true" "$([[ "$(jq -r '.generated_at' "$RESULT")" != "null" ]] && echo true || echo false)"
assert_eq "one template" "1" "$(jq '.templates | length' "$RESULT")"
assert_eq "template name is bug-fix" "bug-fix" "$(jq -r '.templates[0].template' "$RESULT")"
assert_eq "total_runs is 5" "5" "$(jq '.templates[0].total_runs' "$RESULT")"
assert_eq "full_pass_rate is 1.0" "1" "$(jq '.templates[0].full_pass_rate' "$RESULT")"
assert_eq "partial_pass_rate is 0" "0" "$(jq '.templates[0].partial_pass_rate' "$RESULT")"

# Composite score: 1.0*1.0 + 0.0*0.4 - 0*0.2 - 0*0.3 = 1.0
assert_near "score is 1.0 for all-pass" "1.0" "$(jq '.templates[0].score' "$RESULT")"
assert_eq "confidence is medium for 5 runs" "medium" "$(jq -r '.templates[0].confidence' "$RESULT")"

# --- Test: mixed outcomes ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
# 10 runs: 5 full_pass, 3 partial_pass, 1 agent_failure, 1 timeout
for i in $(seq 1 5); do
  make_feedback "bd-m$i" "feature" "aider" "full_pass"
done
for i in $(seq 6 8); do
  make_feedback "bd-m$i" "feature" "aider" "partial_pass"
done
make_feedback "bd-m9" "feature" "aider" "agent_failure"
make_feedback "bd-m10" "feature" "aider" "timeout"
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"

# full_pass_rate = 5/10 = 0.5, partial_pass_rate = 3/10 = 0.3
# retry_rate = 0 (none retried), timeout_rate = 1/10 = 0.1
# score = 0.5*1.0 + 0.3*0.4 - 0*0.2 - 0.1*0.3 = 0.5 + 0.12 - 0 - 0.03 = 0.59
assert_near "mixed score calculation" "0.59" "$(jq '.templates[0].score' "$RESULT")" "0.02"
assert_eq "confidence medium for 10 runs" "medium" "$(jq -r '.templates[0].confidence' "$RESULT")"

# --- Test: confidence levels ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
# Low: 3 runs
for i in $(seq 1 3); do
  make_feedback "bd-low$i" "docs" "claude" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
assert_eq "confidence low for 3 runs" "low" "$(jq -r '.templates[0].confidence' "$RESULT")"

# High: 20 runs
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 20); do
  make_feedback "bd-hi$i" "refactor" "aider" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
assert_eq "confidence high for 20 runs" "high" "$(jq -r '.templates[0].confidence' "$RESULT")"

# --- Test: retry rate ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-r$i" "bug-fix" "claude" "full_pass" "true"
done
for i in $(seq 6 10); do
  make_feedback "bd-r$i" "bug-fix" "claude" "full_pass" "false"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
# retry_rate = 5/10 = 0.5
# score = 1.0*1.0 + 0*0.4 - 0.5*0.2 - 0*0.3 = 1.0 - 0.1 = 0.9
assert_near "retry rate reduces score" "0.9" "$(jq '.templates[0].score' "$RESULT")" "0.02"

# --- Test: score clamping ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
# All timeout + all retried = negative raw score
for i in $(seq 1 10); do
  make_feedback "bd-clamp$i" "bad-template" "claude" "timeout" "true"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
# raw = 0 + 0 - 1.0*0.2 - 1.0*0.3 = -0.5 → clamped to 0
assert_eq "score clamped to 0" "0" "$(jq '.templates[0].score' "$RESULT")"

# --- Test: multiple templates ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-t1-$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 1 5); do
  make_feedback "bd-t2-$i" "feature" "aider" "partial_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
assert_eq "two templates" "2" "$(jq '.templates | length' "$RESULT")"

# --- Test: per-agent breakdown ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 3); do
  make_feedback "bd-ag1-$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 1 3); do
  make_feedback "bd-ag2-$i" "bug-fix" "aider" "partial_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
agent_count="$(jq '.templates[0].agents | length' "$RESULT")"
assert_eq "two agents in breakdown" "2" "$agent_count"
# Check agent fields exist
has_agent_runs="$(jq '[.templates[0].agents[] | has("total_runs")] | all' "$RESULT")"
assert_eq "agent breakdown has total_runs" "true" "$has_agent_runs"
has_agent_pass_rate="$(jq '[.templates[0].agents[] | has("full_pass_rate")] | all' "$RESULT")"
assert_eq "agent breakdown has full_pass_rate" "true" "$has_agent_pass_rate"

# --- Test: trend detection ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
# 20 runs total: first 10 are agent_failure, last 10 are full_pass
# Need timestamps to determine order - use bead names sorted alphabetically
for i in $(seq 1 10); do
  bead="$(printf "bd-trend-a%02d" "$i")"
  make_feedback "$bead" "improving" "claude" "agent_failure"
done
for i in $(seq 11 20); do
  bead="$(printf "bd-trend-b%02d" "$i")"
  make_feedback "$bead" "improving" "claude" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
trend="$(jq -r '.templates[0].trend' "$RESULT")"
assert_eq "improving trend detected" "improving" "$trend"

# Declining trend: last 10 worse than all-time
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 10); do
  bead="$(printf "bd-decline-a%02d" "$i")"
  make_feedback "$bead" "declining" "claude" "full_pass"
done
for i in $(seq 11 20); do
  bead="$(printf "bd-decline-b%02d" "$i")"
  make_feedback "$bead" "declining" "claude" "agent_failure"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
trend="$(jq -r '.templates[0].trend' "$RESULT")"
assert_eq "declining trend detected" "declining" "$trend"

# Stable trend: all same outcome
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 20); do
  bead="$(printf "bd-stable-%02d" "$i")"
  make_feedback "$bead" "stable" "claude" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
trend="$(jq -r '.templates[0].trend' "$RESULT")"
assert_eq "stable trend when consistent" "stable" "$trend"

# No trend when <10 runs
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-notrend$i" "small" "claude" "full_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
trend="$(jq -r '.templates[0].trend' "$RESULT")"
assert_eq "no trend with <10 runs" "insufficient_data" "$trend"

# --- Test: infra failures excluded from scoring ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-infra$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 6 10); do
  make_feedback "bd-infra$i" "bug-fix" "claude" "infra_failure"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
RESULT="$SCORES_DIR/template-scores.json"
# infra_failure should not count toward template score (5 scoreable runs, all full_pass)
assert_eq "total_runs includes infra" "10" "$(jq '.templates[0].total_runs' "$RESULT")"
scoreable="$(jq '.templates[0].scoreable_runs' "$RESULT")"
assert_eq "scoreable_runs excludes infra" "5" "$scoreable"
assert_near "score based on scoreable runs" "1.0" "$(jq '.templates[0].score' "$RESULT")" "0.02"

# --- Summary ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All tests passed!"
