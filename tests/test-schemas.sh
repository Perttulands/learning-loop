#!/usr/bin/env bash
# Tests for US-101: outcome and feedback JSON schemas
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Testing outcome.json schema ==="

OUTCOME="$PROJECT_DIR/config/schemas/outcome.json"

# File exists and is valid JSON
if jq empty "$OUTCOME" >/dev/null; then
  echo "  PASS: outcome.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: outcome.json missing or invalid JSON"
  FAIL=$((FAIL + 1))
fi

# Has schema_version
assert_eq "outcome has schema_version" "true" \
  "$(jq 'has("schema_version")' "$OUTCOME")"

# Has outcome_types array with 5 entries
assert_eq "outcome has 5 outcome_types" "5" \
  "$(jq '.outcome_types | length' "$OUTCOME")"

# Check each outcome type exists
for otype in full_pass partial_pass agent_failure infra_failure timeout; do
  assert_eq "outcome_types contains $otype" "true" \
    "$(jq --arg t "$otype" '[.outcome_types[].name] | index($t) != null' "$OUTCOME")"
done

echo ""
echo "=== Testing feedback.json schema ==="

FEEDBACK="$PROJECT_DIR/config/schemas/feedback.json"

# File exists and is valid JSON
if jq empty "$FEEDBACK" >/dev/null; then
  echo "  PASS: feedback.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: feedback.json missing or invalid JSON"
  FAIL=$((FAIL + 1))
fi

# Has schema_version
assert_eq "feedback has schema_version" "true" \
  "$(jq 'has("schema_version")' "$FEEDBACK")"

# Has all required fields defined
for field in bead timestamp template agent model outcome signals failure_patterns opus_quality_score opus_judge prompt_hash; do
  assert_eq "feedback defines field '$field'" "true" \
    "$(jq --arg f "$field" '.fields | has($f)' "$FEEDBACK")"
done

# Signals sub-fields
for sig in exit_clean tests_pass lint_pass ubs_clean truthsayer_clean duration_ratio retried; do
  assert_eq "feedback signals has '$sig'" "true" \
    "$(jq --arg s "$sig" '.fields.signals.fields | has($s)' "$FEEDBACK")"
done

# outcome field references the outcome types
assert_eq "feedback outcome references outcome_types" "true" \
  "$(jq '.fields.outcome.enum != null' "$FEEDBACK")"

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
