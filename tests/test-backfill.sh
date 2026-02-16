#!/usr/bin/env bash
# Tests for backfill.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKFILL="$PROJECT_DIR/scripts/backfill.sh"

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

setup_env() {
  local test_name="$1"
  local tmp="$TMPDIR_BASE/$test_name"
  mkdir -p "$tmp/runs" "$tmp/feedback" "$tmp/scores"
  echo "$tmp"
}

create_run_record() {
  local dir="$1" bead="$2" status="${3:-done}" exit_code="${4:-0}" template="${5:-custom}"
  local v_tests="${6:-pass}" v_lint="${7:-pass}" v_ubs="${8:-clean}"
  cat > "$dir/runs/$bead.json" <<EOF
{
  "schema_version": 1,
  "bead": "$bead",
  "agent": "claude",
  "model": "sonnet",
  "prompt_hash": "abc123",
  "status": "$status",
  "attempt": 1,
  "duration_seconds": 300,
  "exit_code": $exit_code,
  "failure_reason": null,
  "template_name": "$template",
  "verification": {
    "lint": "$v_lint",
    "tests": "$v_tests",
    "ubs": "$v_ubs",
    "truthsayer": "pass"
  }
}
EOF
}

# --- Test: Usage message ---
output="$("$BACKFILL" 2>&1 || true)"
assert "shows usage without args" '[[ "$output" == *"Usage"* ]]'

# --- Test: Non-existent runs dir ---
output="$("$BACKFILL" /nonexistent/path 2>&1 || true)"
assert "errors on missing runs dir" '[[ "$output" == *"not found"* || "$output" == *"Error"* ]]'

# --- Test: Empty runs directory ---
tmp="$(setup_env empty)"
output="$(FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" 2>&1)"
assert "handles empty runs dir" '[[ "$output" == *"0"* ]]'
assert "no feedback files for empty runs" '[[ $(command ls "$tmp/feedback/"bd-*.json 2>/dev/null | wc -l) -eq 0 ]]'

# --- Test: Single full_pass run ---
tmp="$(setup_env single)"
create_run_record "$tmp" "bd-aaa" "done" 0 "bug-fix" "pass" "pass" "clean"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
assert "creates feedback for single run" '[[ -f "$tmp/feedback/bd-aaa.json" ]]'
assert "feedback has correct bead" '[[ "$(jq -r .bead "$tmp/feedback/bd-aaa.json")" == "bd-aaa" ]]'
assert "feedback outcome is full_pass" '[[ "$(jq -r .outcome "$tmp/feedback/bd-aaa.json")" == "full_pass" ]]'
assert "template-scores.json created" '[[ -f "$tmp/scores/template-scores.json" ]]'
scores_templates="$(jq '.templates | length' "$tmp/scores/template-scores.json")"
assert "scores has 1 template entry" '[[ "$scores_templates" -eq 1 ]]'

# --- Test: Multiple runs, different templates ---
tmp="$(setup_env multi)"
create_run_record "$tmp" "bd-bbb" "done" 0 "bug-fix" "pass" "pass" "clean"
create_run_record "$tmp" "bd-ccc" "done" 0 "feature" "fail" "pass" "clean"
create_run_record "$tmp" "bd-ddd" "done" 1 "bug-fix" "fail" "fail" "clean"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
assert "creates 3 feedback files" '[[ $(command ls "$tmp/feedback/"bd-*.json 2>/dev/null | wc -l) -eq 3 ]]'
assert "scores has 2 template entries" '[[ "$(jq ".templates | length" "$tmp/scores/template-scores.json")" -eq 2 ]]'

# --- Test: Skips running status ---
tmp="$(setup_env skip_running)"
create_run_record "$tmp" "bd-eee" "running" 0 "custom" "pass" "pass" "clean"
create_run_record "$tmp" "bd-fff" "done" 0 "custom" "pass" "pass" "clean"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
assert "skips running, only 1 feedback file" '[[ $(command ls "$tmp/feedback/"bd-*.json 2>/dev/null | wc -l) -eq 1 ]]'
assert "processed run is bd-fff" '[[ -f "$tmp/feedback/bd-fff.json" ]]'
assert "no feedback for running bd-eee" '[[ ! -f "$tmp/feedback/bd-eee.json" ]]'

# --- Test: Pattern registry seeded ---
tmp="$(setup_env registry)"
create_run_record "$tmp" "bd-ggg" "done" 0 "custom" "fail" "fail" "clean"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
registry="$tmp/feedback/pattern-registry.json"
assert "pattern-registry.json created" '[[ -f "$registry" ]]'
assert "registry is valid JSON" 'jq . "$registry" > /dev/null 2>&1'

# --- Test: Summary output ---
tmp="$(setup_env summary)"
create_run_record "$tmp" "bd-hhh" "done" 0 "custom" "pass" "pass" "clean"
create_run_record "$tmp" "bd-iii" "done" 1 "custom" "fail" "pass" "clean"
output="$(FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" 2>&1)"
assert "summary shows processed count" '[[ "$output" == *"2"* ]]'
assert "summary mentions feedback" '[[ "$output" == *"feedback"* || "$output" == *"Feedback"* || "$output" == *"processed"* || "$output" == *"Processed"* ]]'

# --- Test: Idempotent re-run ---
tmp="$(setup_env idempotent)"
create_run_record "$tmp" "bd-jjj" "done" 0 "custom" "pass" "pass" "clean"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
first_outcome="$(jq -r .outcome "$tmp/feedback/bd-jjj.json")"
FEEDBACK_DIR="$tmp/feedback" SCORES_DIR="$tmp/scores" "$BACKFILL" "$tmp/runs" > /dev/null 2>&1
second_outcome="$(jq -r .outcome "$tmp/feedback/bd-jjj.json")"
assert "idempotent: same outcome on re-run" '[[ "$first_outcome" == "$second_outcome" ]]'

# --- Results ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
