#!/usr/bin/env bash
# test-selection-validation.sh - Validate select-template.sh against real task descriptions
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_empty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (empty)"
    FAIL=$((FAIL + 1))
  fi
}

SELECT="$PROJECT_DIR/scripts/select-template.sh"
REPORT="$PROJECT_DIR/state/reports/selection-validation.md"
VALIDATE="$PROJECT_DIR/scripts/validate-selection.sh"

# --- Setup: ensure scores exist ---
RUNS_DIR="$HOME/.openclaw/workspace/state/runs"
if [[ ! -f "$PROJECT_DIR/state/scores/template-scores.json" ]]; then
  bash "$PROJECT_DIR/scripts/backfill.sh" "$RUNS_DIR" >/dev/null 2>&1
fi

# --- Test 1: validate-selection.sh exists and is executable ---
echo "=== Validation script existence ==="
assert_eq "validate-selection.sh exists" "true" "$(test -f "$VALIDATE" && echo true || echo false)"
assert_eq "validate-selection.sh is executable" "true" "$(test -x "$VALIDATE" && echo true || echo false)"

# --- Test 2: Report generation ---
echo "=== Report generation ==="
if [[ -f "$REPORT" ]]; then rm "$REPORT"; fi
bash "$VALIDATE" "$RUNS_DIR" >/dev/null 2>&1
assert_eq "Report file created" "true" "$(test -f "$REPORT" && echo true || echo false)"
assert_not_empty "Report has content" "$(cat "$REPORT" 2>/dev/null)"

# --- Test 3: Report structure ---
echo "=== Report structure ==="
REPORT_CONTENT="$(cat "$REPORT")"
assert_contains "Report has title" "Selection Validation" "$REPORT_CONTENT"
assert_contains "Report has summary section" "Summary" "$REPORT_CONTENT"
assert_contains "Report has results table" "Task Type" "$REPORT_CONTENT"
assert_contains "Report has accuracy metric" "Accuracy" "$REPORT_CONTENT"

# --- Test 4: Classification accuracy on diverse prompts ---
echo "=== Task classification accuracy ==="

# Bug fix prompts → bug-fix
result=$(bash "$SELECT" "Fix command injection vulnerability in tmux services" | jq -r '.task_type')
assert_eq "Fix prompt → bug-fix" "bug-fix" "$result"

result=$(bash "$SELECT" "Fix 3 hanging frontend tests" | jq -r '.task_type')
assert_eq "Fix tests prompt → bug-fix" "bug-fix" "$result"

result=$(bash "$SELECT" "Debug memory leak in worker process" | jq -r '.task_type')
assert_eq "Debug prompt → bug-fix" "bug-fix" "$result"

# Feature prompts → feature
result=$(bash "$SELECT" "Add beads integration to Truthsayer" | jq -r '.task_type')
assert_eq "Add prompt → feature" "feature" "$result"

result=$(bash "$SELECT" "Create a new file string_utils.py with functions" | jq -r '.task_type')
assert_eq "Create prompt → feature" "feature" "$result"

result=$(bash "$SELECT" "Implement Phase 1 of the Athena Portal Expansion" | jq -r '.task_type')
assert_eq "Implement prompt → feature" "feature" "$result"

# Doc prompts → docs
result=$(bash "$SELECT" "Write a complete PRD at docs/PRD.md for Truthsayer" | jq -r '.task_type')
assert_eq "PRD/doc prompt → docs" "docs" "$result"

# Review prompts → code-review
result=$(bash "$SELECT" "Review completed Sprint 1 foundation of Athena Web" | jq -r '.task_type')
assert_eq "Review prompt → code-review" "code-review" "$result"

result=$(bash "$SELECT" "Code review: Oathkeeper reliability and performance" | jq -r '.task_type')
assert_eq "Code review prompt → code-review" "code-review" "$result"

# Script prompts → script
result=$(bash "$SELECT" "Write a bash script to automate deployment" | jq -r '.task_type')
assert_eq "Script prompt → script" "script" "$result"

# --- Test 5: Output format is valid JSON with required fields ---
echo "=== Output format ==="
output=$(bash "$SELECT" "Fix a bug in the login flow")
assert_eq "Output is valid JSON" "true" "$(echo "$output" | jq empty 2>/dev/null && echo true || echo false)"
assert_not_empty "Has template field" "$(echo "$output" | jq -r '.template')"
assert_not_empty "Has agent field" "$(echo "$output" | jq -r '.agent')"
assert_not_empty "Has task_type field" "$(echo "$output" | jq -r '.task_type')"
assert_not_empty "Has reasoning field" "$(echo "$output" | jq -r '.reasoning')"
assert_not_empty "Has confidence field" "$(echo "$output" | jq -r '.confidence')"

# --- Test 6: Report includes at least 10 test cases ---
echo "=== Report completeness ==="
# Count table rows (lines with | that aren't headers or separators)
table_rows=$(grep -c '^|.*|.*|.*|' "$REPORT" 2>/dev/null || echo 0)
# Subtract header and separator rows
data_rows=$((table_rows - 2))
assert_eq "Report has ≥10 test cases" "true" "$([ "$data_rows" -ge 10 ] && echo true || echo false)"

# --- Test 7: Edge cases documented ---
echo "=== Edge cases ==="
assert_contains "Report documents edge cases" "Edge" "$REPORT_CONTENT"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
