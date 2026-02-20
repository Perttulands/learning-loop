#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/opus-judge.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_pass="$TMPDIR_BASE/run-pass.json"
run_fail="$TMPDIR_BASE/run-fail.json"

cat > "$run_pass" <<'JSON'
{
  "bead": "athena-pass",
  "agent": "claude",
  "model": "sonnet",
  "template_name": "bug-fix",
  "status": "done",
  "exit_code": 0,
  "verification": {
    "tests": "pass",
    "lint": "pass",
    "ubs": "clean",
    "truthsayer": "pass"
  }
}
JSON

cat > "$run_fail" <<'JSON'
{
  "bead": "athena-fail",
  "agent": "codex",
  "model": "gpt-5-codex",
  "template_name": "feature",
  "status": "failed",
  "exit_code": 1,
  "verification": {
    "tests": "fail",
    "lint": "fail",
    "ubs": "issues",
    "truthsayer": "fail"
  }
}
JSON

pass_out="$($SCRIPT "$run_pass")"
fail_out="$($SCRIPT "$run_fail")"

assert_eq "pass output is json" "0" "$(echo "$pass_out" | jq empty >/dev/null 2>&1; echo $?)"
assert_eq "fail output is json" "0" "$(echo "$fail_out" | jq empty >/dev/null 2>&1; echo $?)"

assert_eq "pass bead" "athena-pass" "$(echo "$pass_out" | jq -r '.bead')"
assert_eq "fail bead" "athena-fail" "$(echo "$fail_out" | jq -r '.bead')"
assert_eq "judge model default" "opus" "$(echo "$pass_out" | jq -r '.judge_model')"
assert_eq "has quality score field" "true" "$(echo "$pass_out" | jq 'has("quality_score")')"
assert_eq "has critique" "true" "$(echo "$pass_out" | jq '(.critique | length) > 0')"
assert_eq "has findings array" "array" "$(echo "$fail_out" | jq -r '.findings | type')"

pass_score="$(echo "$pass_out" | jq -r '.quality_score')"
fail_score="$(echo "$fail_out" | jq -r '.quality_score')"
assert_eq "pass score greater than fail score" "1" "$(echo "$pass_score > $fail_score" | bc -l | cut -d'.' -f1)"

assert_eq "pass verdict is pass or partial" "true" "$(echo "$pass_out" | jq '.verdict == "pass" or .verdict == "partial"')"
assert_eq "fail verdict is fail or partial" "true" "$(echo "$fail_out" | jq '.verdict == "fail" or .verdict == "partial"')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
