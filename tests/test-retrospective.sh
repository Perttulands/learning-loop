#!/usr/bin/env bash
# Tests for scripts/retrospective.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RETRO="$PROJECT_DIR/scripts/retrospective.sh"

PASS=0
FAIL=0
assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected NOT to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}
assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_test() {
  local td="$TMPDIR_BASE/test_$$_$RANDOM"
  mkdir -p "$td/feedback" "$td/scores" "$td/reports"
  echo "$td"
}

# Create a feedback record helper
create_feedback() {
  local dir="$1" bead="$2" outcome="$3" template="$4" timestamp="$5"
  local agent="${6:-claude}" retried="${7:-false}"
  local tests_pass=true lint_pass=true
  if [[ "$outcome" == "agent_failure" ]]; then
    tests_pass=false
    lint_pass=false
  elif [[ "$outcome" == "partial_pass" ]]; then
    tests_pass=false
  fi
  cat > "$dir/$bead.json" <<EOF
{
  "schema_version": "1.0.0",
  "bead": "$bead",
  "timestamp": "$timestamp",
  "template": "$template",
  "agent": "$agent",
  "model": "sonnet-4",
  "outcome": "$outcome",
  "signals": {
    "exit_clean": $([ "$outcome" != "agent_failure" ] && echo true || echo false),
    "tests_pass": $tests_pass,
    "lint_pass": $lint_pass,
    "ubs_clean": true,
    "truthsayer_clean": true,
    "duration_ratio": 0.5,
    "retried": $retried
  },
  "failure_patterns": [],
  "prompt_hash": "hash-$bead"
}
EOF
}

# --- Test 1: Script exists and is executable ---
assert "script exists" test -f "$RETRO"
assert "script is executable" test -x "$RETRO"

# --- Test 2: Usage message ---
out="$(FEEDBACK_DIR=/nonexistent "$RETRO" --help 2>&1 || true)"
assert_contains "usage shows help" "$out" "Usage"

# --- Test 3: Missing feedback dir ---
out="$(FEEDBACK_DIR=/nonexistent "$RETRO" 2>&1 || true)"
assert_contains "error on missing dir" "$out" "Error"

# --- Test 4: Empty feedback dir ---
td="$(setup_test)"
out="$(FEEDBACK_DIR="$td/feedback" REPORTS_DIR="$td/reports" "$RETRO" 2>&1)"
assert_contains "empty dir message" "$out" "0"

# --- Test 5-8: Pre/post split with boundary date ---
td="$(setup_test)"
# Pre-loop: older timestamps
create_feedback "$td/feedback" "bd-001" "agent_failure" "custom" "2025-01-01T00:00:00Z"
create_feedback "$td/feedback" "bd-002" "partial_pass" "custom" "2025-01-02T00:00:00Z"
create_feedback "$td/feedback" "bd-003" "full_pass" "custom" "2025-01-03T00:00:00Z"
create_feedback "$td/feedback" "bd-004" "agent_failure" "custom" "2025-01-04T00:00:00Z"
create_feedback "$td/feedback" "bd-005" "agent_failure" "custom" "2025-01-05T00:00:00Z"
# Post-loop: newer timestamps
create_feedback "$td/feedback" "bd-006" "full_pass" "bug-fix" "2025-06-01T00:00:00Z"
create_feedback "$td/feedback" "bd-007" "full_pass" "bug-fix" "2025-06-02T00:00:00Z"
create_feedback "$td/feedback" "bd-008" "full_pass" "feature" "2025-06-03T00:00:00Z"
create_feedback "$td/feedback" "bd-009" "partial_pass" "bug-fix" "2025-06-04T00:00:00Z"
create_feedback "$td/feedback" "bd-010" "full_pass" "feature" "2025-06-05T00:00:00Z"

out="$(FEEDBACK_DIR="$td/feedback" REPORTS_DIR="$td/reports" "$RETRO" --boundary "2025-03-01" 2>&1)"
report="$td/reports/retrospective.json"

assert "report file created" test -f "$report"
# Check pre-loop pass rate (1 full_pass out of 5 = 0.2)
pre_pass_rate="$(jq '.pre_loop.full_pass_rate' "$report")"
assert_eq "pre pass rate 0.2" "$pre_pass_rate" "0.2"
# Check post-loop pass rate (4 full_pass out of 5 = 0.8)
post_pass_rate="$(jq '.post_loop.full_pass_rate' "$report")"
assert_eq "post pass rate 0.8" "$post_pass_rate" "0.8"
# Check improvement delta (use numeric comparison for float precision)
delta="$(jq '.improvement.pass_rate_delta * 10 | round / 10' "$report")"
assert_eq "pass rate delta 0.6" "$delta" "0.6"

# --- Test 9-11: Template usage ---
pre_template_pct="$(jq '.pre_loop.template_usage_rate' "$report")"
assert_eq "pre template usage 0" "$pre_template_pct" "0"
post_template_pct="$(jq '.post_loop.template_usage_rate' "$report")"
assert_eq "post template usage 1" "$post_template_pct" "1"
template_delta="$(jq '.improvement.template_usage_delta' "$report")"
assert_eq "template usage delta" "$template_delta" "1"

# --- Test 12-13: Failure pattern comparison ---
# Create records with failure patterns
td2="$(setup_test)"
create_feedback "$td2/feedback" "bd-001" "agent_failure" "custom" "2025-01-01T00:00:00Z"
jq '.failure_patterns = ["test-failure-after-completion", "scope-creep"]' "$td2/feedback/bd-001.json" > "$td2/feedback/bd-001.tmp" && mv "$td2/feedback/bd-001.tmp" "$td2/feedback/bd-001.json"
create_feedback "$td2/feedback" "bd-002" "agent_failure" "custom" "2025-01-02T00:00:00Z"
jq '.failure_patterns = ["test-failure-after-completion"]' "$td2/feedback/bd-002.json" > "$td2/feedback/bd-002.tmp" && mv "$td2/feedback/bd-002.tmp" "$td2/feedback/bd-002.json"
create_feedback "$td2/feedback" "bd-003" "full_pass" "bug-fix" "2025-06-01T00:00:00Z"
create_feedback "$td2/feedback" "bd-004" "partial_pass" "bug-fix" "2025-06-02T00:00:00Z"
jq '.failure_patterns = ["test-failure-after-completion"]' "$td2/feedback/bd-004.json" > "$td2/feedback/bd-004.tmp" && mv "$td2/feedback/bd-004.tmp" "$td2/feedback/bd-004.json"

out="$(FEEDBACK_DIR="$td2/feedback" REPORTS_DIR="$td2/reports" "$RETRO" --boundary "2025-03-01" 2>&1)"
report2="$td2/reports/retrospective.json"

pre_patterns="$(jq '.pre_loop.top_failure_patterns | length' "$report2")"
assert "pre-loop has failure patterns" test "$pre_patterns" -gt 0
pre_top="$(jq -r '.pre_loop.top_failure_patterns[0].pattern' "$report2")"
assert_eq "pre top pattern" "$pre_top" "test-failure-after-completion"

# --- Test 14-15: Retry rate comparison ---
td3="$(setup_test)"
create_feedback "$td3/feedback" "bd-001" "full_pass" "custom" "2025-01-01T00:00:00Z" "claude" "true"
create_feedback "$td3/feedback" "bd-002" "full_pass" "custom" "2025-01-02T00:00:00Z" "claude" "true"
create_feedback "$td3/feedback" "bd-003" "full_pass" "custom" "2025-01-03T00:00:00Z" "claude" "false"
create_feedback "$td3/feedback" "bd-004" "full_pass" "bug-fix" "2025-06-01T00:00:00Z" "claude" "false"
create_feedback "$td3/feedback" "bd-005" "full_pass" "bug-fix" "2025-06-02T00:00:00Z" "claude" "false"

out="$(FEEDBACK_DIR="$td3/feedback" REPORTS_DIR="$td3/reports" "$RETRO" --boundary "2025-03-01" 2>&1)"
report3="$td3/reports/retrospective.json"

pre_retry="$(jq '.pre_loop.retry_rate' "$report3")"
# 2/3 retried
assert_contains "pre retry rate > 0" "$pre_retry" "0.6"
post_retry="$(jq '.post_loop.retry_rate' "$report3")"
assert_eq "post retry rate 0" "$post_retry" "0"

# --- Test 16-17: Threshold tuning opportunities ---
# When pass rate improved significantly, should suggest loosening refinement threshold
td4="$(setup_test)"
for i in $(seq 1 10); do
  create_feedback "$td4/feedback" "bd-pre-$i" "agent_failure" "custom" "2025-01-0${i}T00:00:00Z"
done
for i in $(seq 1 10); do
  create_feedback "$td4/feedback" "bd-post-$i" "full_pass" "bug-fix" "2025-06-0${i}T00:00:00Z"
done

out="$(FEEDBACK_DIR="$td4/feedback" REPORTS_DIR="$td4/reports" "$RETRO" --boundary "2025-03-01" 2>&1)"
report4="$td4/reports/retrospective.json"

tuning="$(jq '.threshold_tuning | length' "$report4")"
assert "has tuning suggestions" test "$tuning" -gt 0
assert_contains "stdout shows improvement" "$out" "pass rate"

# --- Test 18: Auto-detect boundary ---
# Without --boundary, should use earliest non-custom template timestamp
td5="$(setup_test)"
create_feedback "$td5/feedback" "bd-001" "agent_failure" "custom" "2025-01-01T00:00:00Z"
create_feedback "$td5/feedback" "bd-002" "full_pass" "bug-fix" "2025-06-01T00:00:00Z"
create_feedback "$td5/feedback" "bd-003" "full_pass" "bug-fix" "2025-06-02T00:00:00Z"

out="$(FEEDBACK_DIR="$td5/feedback" REPORTS_DIR="$td5/reports" "$RETRO" 2>&1)"
report5="$td5/reports/retrospective.json"

assert "auto-boundary report created" test -f "$report5"
boundary="$(jq -r '.boundary' "$report5")"
assert_contains "boundary detected" "$boundary" "2025-06-01"

# --- Test 19: Schema version ---
assert_eq "schema version" "$(jq -r '.schema_version' "$report5")" "1.0.0"

# --- Test 20: Run counts ---
pre_runs="$(jq '.pre_loop.total_runs' "$report")"
assert_eq "pre_loop runs" "$pre_runs" "5"
post_runs="$(jq '.post_loop.total_runs' "$report")"
assert_eq "post_loop runs" "$post_runs" "5"

# --- Test 21: Infra exclusion ---
td6="$(setup_test)"
create_feedback "$td6/feedback" "bd-001" "infra_failure" "custom" "2025-01-01T00:00:00Z"
create_feedback "$td6/feedback" "bd-002" "full_pass" "custom" "2025-01-02T00:00:00Z"
create_feedback "$td6/feedback" "bd-003" "full_pass" "bug-fix" "2025-06-01T00:00:00Z"

out="$(FEEDBACK_DIR="$td6/feedback" REPORTS_DIR="$td6/reports" "$RETRO" --boundary "2025-03-01" 2>&1)"
report6="$td6/reports/retrospective.json"
# Infra failures should be excluded from pass rate calculation
pre_pr="$(jq '.pre_loop.full_pass_rate' "$report6")"
assert_eq "infra excluded from pass rate" "$pre_pr" "1"

# --- Test 22: Outcome breakdown ---
outcome_types="$(jq '.pre_loop.outcome_breakdown | keys | length' "$report")"
assert "outcome breakdown has entries" test "$outcome_types" -gt 0

# --- Test 23: Human-readable stdout ---
assert_contains "stdout has summary" "$out" "Retrospective"

# --- Test 24: Per-template breakdown in post-loop ---
templates_count="$(jq '.post_loop.template_breakdown | length' "$report")"
assert "post has template breakdown" test "$templates_count" -gt 0

# --- Test 25: All pre-loop records are custom ---
pre_custom="$(jq '.pre_loop.outcome_breakdown.agent_failure' "$report")"
assert_eq "pre agent_failure count" "$pre_custom" "3"

# --- Results ---
echo ""
echo "test-retrospective.sh: $PASS passed, $FAIL failed (of $((PASS + FAIL)) total)"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
