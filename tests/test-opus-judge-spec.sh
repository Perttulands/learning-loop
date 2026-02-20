#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

SPEC_FILE="$PROJECT_DIR/docs/opus-judge-spec.md"
INPUT_SCHEMA="$PROJECT_DIR/config/schemas/opus-judge-input.json"
OUTPUT_SCHEMA="$PROJECT_DIR/config/schemas/opus-judge-output.json"

assert_eq "spec file exists" "true" "$([ -f "$SPEC_FILE" ] && echo true || echo false)"
assert_eq "input schema exists" "true" "$([ -f "$INPUT_SCHEMA" ] && echo true || echo false)"
assert_eq "output schema exists" "true" "$([ -f "$OUTPUT_SCHEMA" ] && echo true || echo false)"

assert_eq "input schema valid json" "0" "$(jq empty "$INPUT_SCHEMA" >/dev/null 2>&1; echo $?)"
assert_eq "output schema valid json" "0" "$(jq empty "$OUTPUT_SCHEMA" >/dev/null 2>&1; echo $?)"

assert_eq "input schema has bead field" "true" "$(jq '.fields | has("bead")' "$INPUT_SCHEMA")"
assert_eq "output schema has quality_score field" "true" "$(jq '.fields | has("quality_score")' "$OUTPUT_SCHEMA")"
assert_eq "output schema has verdict enum" "true" "$(jq '.fields.verdict.enum | index("pass") != null and index("partial") != null and index("fail") != null' "$OUTPUT_SCHEMA")"

assert_eq "spec mentions invocation" "true" "$(grep -q 'scripts/opus-judge.sh' "$SPEC_FILE" && echo true || echo false)"
assert_eq "spec mentions input contract" "true" "$(grep -q 'Input Contract' "$SPEC_FILE" && echo true || echo false)"
assert_eq "spec mentions output contract" "true" "$(grep -q 'Output Contract' "$SPEC_FILE" && echo true || echo false)"


echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
