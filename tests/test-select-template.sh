#!/usr/bin/env bash
# Tests for select-template.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELECT_SCRIPT="$PROJECT_DIR/scripts/select-template.sh"

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

# Setup temp dirs
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SCORES_DIR="$TMPDIR_TEST/scores"
mkdir -p "$SCORES_DIR"

# Helper: create template-scores.json with given templates array
make_scores() {
  local templates_json="$1"
  cat > "$SCORES_DIR/template-scores.json" <<EOF
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-16T10:00:00Z",
  "templates": $templates_json
}
EOF
}

# Helper: create a template entry JSON
tpl_entry() {
  local name="$1" score="$2" confidence="$3" runs="$4" agents_json="${5:-[]}"
  cat <<EOF
{
  "template": "$name",
  "total_runs": $runs,
  "scoreable_runs": $runs,
  "full_pass_rate": $score,
  "partial_pass_rate": 0,
  "retry_rate": 0,
  "timeout_rate": 0,
  "score": $score,
  "confidence": "$confidence",
  "trend": "stable",
  "agents": $agents_json
}
EOF
}

# --- Test: usage message ---
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" 2>&1 || true)"
assert_eq "shows usage with no args" "0" "$([[ "$output" == *"Usage"* ]] && echo 0 || echo 1)"

# --- Test: task type classification ---
# fix/bug → bug-fix
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the login crash" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "fix → bug-fix" "bug-fix" "$task_type"

output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "debug the null pointer bug" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "bug → bug-fix" "bug-fix" "$task_type"

# add/create → feature
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "add user authentication" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "add → feature" "feature" "$task_type"

output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "create a new endpoint" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "create → feature" "feature" "$task_type"

# refactor → refactor
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "refactor the database layer" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "refactor → refactor" "refactor" "$task_type"

# doc → docs
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "document the API" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "document → docs" "docs" "$task_type"

# script → script
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "write a script to deploy" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "script → script" "script" "$task_type"

# review → code-review
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "review the pull request" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "review → code-review" "code-review" "$task_type"

# fallback → custom
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "do something unusual" 2>/dev/null)"
task_type="$(echo "$output" | jq -r '.task_type')"
assert_eq "fallback → custom" "custom" "$task_type"

# --- Test: output format ---
agents_json='[{"agent": "claude", "total_runs": 5, "full_pass_rate": 0.8, "score": 0.8}]'
make_scores "[$(tpl_entry "bug-fix" 0.8 "medium" 10 "$agents_json")]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the crash" 2>/dev/null)"

assert_eq "valid JSON output" "0" "$(echo "$output" | jq empty 2>&1 | wc -l)"
assert_eq "has template field" "bug-fix" "$(echo "$output" | jq -r '.template')"
assert_eq "has score field" "0.8" "$(echo "$output" | jq '.score')"
assert_eq "has confidence field" "medium" "$(echo "$output" | jq -r '.confidence')"
assert_eq "has agent field" "claude" "$(echo "$output" | jq -r '.agent')"
assert_eq "has reasoning field" "true" "$([[ "$(echo "$output" | jq -r '.reasoning')" != "null" ]] && echo true || echo false)"

# --- Test: score lookup with confidence gating ---
# Low confidence should produce a warning
make_scores "[$(tpl_entry "bug-fix" 0.9 "low" 3)]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the bug" 2>/dev/null)"
has_warning="$(echo "$output" | jq '[.warnings[] | select(. | test("confidence"))] | length > 0')"
assert_eq "low confidence produces warning" "true" "$has_warning"

# Medium confidence should not produce confidence warning
agents_json='[{"agent": "claude", "total_runs": 5, "full_pass_rate": 0.8, "score": 0.8}]'
make_scores "[$(tpl_entry "bug-fix" 0.8 "medium" 10 "$agents_json")]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the bug" 2>/dev/null)"
has_conf_warning="$(echo "$output" | jq '[.warnings[] | select(. | test("confidence"))] | length > 0')"
assert_eq "medium confidence no warning" "false" "$has_conf_warning"

# --- Test: agent recommendation picks highest full_pass_rate (min 3 runs) ---
agents_json='[
  {"agent": "claude", "total_runs": 5, "full_pass_rate": 0.6, "score": 0.6},
  {"agent": "aider", "total_runs": 5, "full_pass_rate": 0.9, "score": 0.9}
]'
make_scores "[$(tpl_entry "bug-fix" 0.7 "medium" 10 "$agents_json")]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the crash" 2>/dev/null)"
assert_eq "picks agent with highest pass rate" "aider" "$(echo "$output" | jq -r '.agent')"

# Agent with <3 runs should be skipped
agents_json='[
  {"agent": "claude", "total_runs": 5, "full_pass_rate": 0.6, "score": 0.6},
  {"agent": "aider", "total_runs": 2, "full_pass_rate": 1.0, "score": 1.0}
]'
make_scores "[$(tpl_entry "bug-fix" 0.7 "medium" 7 "$agents_json")]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the crash" 2>/dev/null)"
assert_eq "skips agent with <3 runs" "claude" "$(echo "$output" | jq -r '.agent')"

# --- Test: no scores file ---
rm -f "$SCORES_DIR/template-scores.json"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the bug" 2>/dev/null)"
template="$(echo "$output" | jq -r '.template')"
assert_eq "no scores → custom template" "custom" "$template"
has_warning="$(echo "$output" | jq '[.warnings[] | select(. | test("scores"))] | length > 0')"
assert_eq "no scores produces warning" "true" "$has_warning"

# --- Test: no matching template in scores ---
make_scores "[$(tpl_entry "feature" 0.8 "high" 25)]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the crash" 2>/dev/null)"
template="$(echo "$output" | jq -r '.template')"
assert_eq "no match → task_type as template" "bug-fix" "$template"
confidence="$(echo "$output" | jq -r '.confidence')"
assert_eq "no match → none confidence" "none" "$confidence"

# --- Test: multiple templates, picks matching one ---
agents_json='[{"agent": "claude", "total_runs": 5, "full_pass_rate": 0.9, "score": 0.9}]'
make_scores "[$(tpl_entry "bug-fix" 0.9 "high" 25 "$agents_json"), $(tpl_entry "feature" 0.5 "medium" 10)]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the login bug" 2>/dev/null)"
assert_eq "selects matching template" "bug-fix" "$(echo "$output" | jq -r '.template')"
assert_eq "uses matching score" "0.9" "$(echo "$output" | jq '.score')"

# --- Test: warnings field is always present (even if empty) ---
agents_json='[{"agent": "claude", "total_runs": 10, "full_pass_rate": 0.8, "score": 0.8}]'
make_scores "[$(tpl_entry "bug-fix" 0.8 "high" 25 "$agents_json")]"
output="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "fix the crash" 2>/dev/null)"
assert_eq "warnings is array" "true" "$(echo "$output" | jq '.warnings | type == "array"')"

# --- Summary ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All tests passed!"
