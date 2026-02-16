#!/usr/bin/env bash
# Tests for agent-scores.json generation (US-202)
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

# Helper: create a feedback record with failure_patterns and duration
make_feedback() {
  local bead="$1" template="$2" agent="$3" outcome="$4"
  local retried="${5:-false}" duration_ratio="${6:-0.5}" patterns="${7:-[]}"
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
    "duration_ratio": $duration_ratio,
    "retried": $retried
  },
  "failure_patterns": $patterns,
  "prompt_hash": "abc123"
}
EOF
}

# --- Test: empty feedback produces empty agent-scores ---
EMPTY_DIR="$TMPDIR_TEST/empty_feedback"
mkdir -p "$EMPTY_DIR"
FEEDBACK_DIR="$EMPTY_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"
assert_eq "agent-scores.json created for empty input" "true" "$([[ -f "$AGENT_RESULT" ]] && echo true || echo false)"
assert_eq "empty agent-scores has empty agents" "0" "$(jq '.agents | length' "$AGENT_RESULT")"

# --- Test: single agent, basic stats ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-a$i" "bug-fix" "claude" "full_pass" "false" "0.4"
done
make_feedback "bd-a6" "bug-fix" "claude" "partial_pass" "false" "0.8"
make_feedback "bd-a7" "bug-fix" "claude" "agent_failure" "false" "1.2"
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"

assert_eq "agent-scores.json exists" "true" "$([[ -f "$AGENT_RESULT" ]] && echo true || echo false)"
assert_eq "valid JSON" "0" "$(jq empty "$AGENT_RESULT" 2>&1 | wc -l)"
assert_eq "has schema_version" "1.0.0" "$(jq -r '.schema_version' "$AGENT_RESULT")"
assert_eq "has generated_at" "true" "$([[ "$(jq -r '.generated_at' "$AGENT_RESULT")" != "null" ]] && echo true || echo false)"
assert_eq "one agent" "1" "$(jq '.agents | length' "$AGENT_RESULT")"
assert_eq "agent name" "claude" "$(jq -r '.agents[0].agent' "$AGENT_RESULT")"
assert_eq "total_runs is 7" "7" "$(jq '.agents[0].total_runs' "$AGENT_RESULT")"
assert_near "pass_rate is 5/7" "0.714" "$(jq '.agents[0].pass_rate' "$AGENT_RESULT")" "0.01"

# --- Test: avg_duration ---
assert_near "avg_duration_ratio" "0.6" "$(jq '.agents[0].avg_duration_ratio' "$AGENT_RESULT")" "0.05"

# --- Test: top failure patterns ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 3); do
  make_feedback "bd-fp$i" "bug-fix" "claude" "agent_failure" "false" "0.5" '["test-failure-after-completion", "lint-failure-after-completion"]'
done
for i in $(seq 4 5); do
  make_feedback "bd-fp$i" "bug-fix" "claude" "partial_pass" "false" "0.5" '["scope-creep"]'
done
make_feedback "bd-fp6" "bug-fix" "claude" "full_pass" "false" "0.5"
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"

assert_eq "top_failure_patterns is array" "true" "$(jq '.agents[0].top_failure_patterns | type == "array"' "$AGENT_RESULT")"
# test-failure-after-completion appears 3 times, lint-failure 3 times, scope-creep 2 times
top_pattern="$(jq -r '.agents[0].top_failure_patterns[0].pattern' "$AGENT_RESULT")"
assert_eq "top pattern count order" "true" "$([[ "$top_pattern" == "test-failure-after-completion" || "$top_pattern" == "lint-failure-after-completion" ]] && echo true || echo false)"

# --- Test: per-agent per-template breakdown ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 4); do
  make_feedback "bd-pt1-$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 1 3); do
  make_feedback "bd-pt2-$i" "feature" "claude" "partial_pass"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"

assert_eq "has templates breakdown" "true" "$(jq '.agents[0] | has("templates")' "$AGENT_RESULT")"
assert_eq "two templates in breakdown" "2" "$(jq '.agents[0].templates | length' "$AGENT_RESULT")"
# Check per-template fields
has_tpl_name="$(jq '[.agents[0].templates[] | has("template")] | all' "$AGENT_RESULT")"
assert_eq "template breakdown has template name" "true" "$has_tpl_name"
has_tpl_runs="$(jq '[.agents[0].templates[] | has("total_runs")] | all' "$AGENT_RESULT")"
assert_eq "template breakdown has total_runs" "true" "$has_tpl_runs"
has_tpl_score="$(jq '[.agents[0].templates[] | has("score")] | all' "$AGENT_RESULT")"
assert_eq "template breakdown has score" "true" "$has_tpl_score"

# --- Test: multiple agents ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-ma1-$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 1 5); do
  make_feedback "bd-ma2-$i" "bug-fix" "aider" "partial_pass"
done
for i in $(seq 1 3); do
  make_feedback "bd-ma3-$i" "feature" "codex" "agent_failure"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"

assert_eq "three agents" "3" "$(jq '.agents | length' "$AGENT_RESULT")"
# Claude should have highest pass_rate
claude_rate="$(jq '[.agents[] | select(.agent == "claude")] | .[0].pass_rate' "$AGENT_RESULT")"
aider_rate="$(jq '[.agents[] | select(.agent == "aider")] | .[0].pass_rate' "$AGENT_RESULT")"
assert_eq "claude pass_rate > aider pass_rate" "1" "$(echo "$claude_rate > $aider_rate" | bc -l)"

# --- Test: infra failures excluded from pass_rate ---
rm -f "$FEEDBACK_DIR"/*.json "$SCORES_DIR"/*.json
for i in $(seq 1 5); do
  make_feedback "bd-inf$i" "bug-fix" "claude" "full_pass"
done
for i in $(seq 6 10); do
  make_feedback "bd-inf$i" "bug-fix" "claude" "infra_failure"
done
FEEDBACK_DIR="$FEEDBACK_DIR" SCORES_DIR="$SCORES_DIR" "$SCORE_SCRIPT"
AGENT_RESULT="$SCORES_DIR/agent-scores.json"

assert_eq "total_runs includes infra" "10" "$(jq '.agents[0].total_runs' "$AGENT_RESULT")"
assert_near "pass_rate excludes infra" "1.0" "$(jq '.agents[0].pass_rate' "$AGENT_RESULT")" "0.02"

# --- Test: template-scores.json still generated correctly ---
TEMPLATE_RESULT="$SCORES_DIR/template-scores.json"
assert_eq "template-scores.json still exists" "true" "$([[ -f "$TEMPLATE_RESULT" ]] && echo true || echo false)"
assert_eq "template-scores valid JSON" "0" "$(jq empty "$TEMPLATE_RESULT" 2>&1 | wc -l)"

# --- Summary ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All tests passed!"
