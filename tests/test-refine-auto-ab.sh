#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REFINE_SCRIPT="$PROJECT_DIR/scripts/refine-prompts.sh"

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

SCORES_DIR="$TMPDIR_BASE/scores"
TEMPLATES_DIR="$TMPDIR_BASE/templates"
FEEDBACK_DIR="$TMPDIR_BASE/feedback"
REGISTRY_FILE="$FEEDBACK_DIR/pattern-registry.json"
REFINEMENT_LOG="$SCORES_DIR/refinement-log.json"
AB_TESTS_FILE="$SCORES_DIR/ab-tests.json"
mkdir -p "$SCORES_DIR" "$TEMPLATES_DIR" "$FEEDBACK_DIR"

cat > "$SCORES_DIR/template-scores.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-20T00:00:00Z",
  "templates": [
    {
      "template": "bug-fix",
      "total_runs": 14,
      "scoreable_runs": 14,
      "full_pass_rate": 0.30,
      "partial_pass_rate": 0.20,
      "retry_rate": 0.10,
      "timeout_rate": 0.05,
      "score": 0.31,
      "confidence": "medium",
      "trend": "stable",
      "agents": []
    }
  ]
}
JSON

cat > "$TEMPLATES_DIR/bug-fix.md" <<'EOF_TPL'
# Bug Fix Template
Run tests before completion.
EOF_TPL

cat > "$REGISTRY_FILE" <<'JSON'
{
  "test-failure-after-completion": {
    "count": 8,
    "first_seen": "2026-02-01T00:00:00Z",
    "last_seen": "2026-02-20T00:00:00Z",
    "last_beads": ["athena-a1"]
  }
}
JSON

SCORES_DIR="$SCORES_DIR" \
TEMPLATES_DIR="$TEMPLATES_DIR" \
REGISTRY_FILE="$REGISTRY_FILE" \
REFINEMENT_LOG="$REFINEMENT_LOG" \
AB_TESTS_FILE="$AB_TESTS_FILE" \
AB_TEST_TARGET_RUNS="10" \
bash "$REFINE_SCRIPT" --auto >/dev/null

assert_eq "variant file created" "true" "$([ -f "$TEMPLATES_DIR/bug-fix-v1.md" ] && echo true || echo false)"
assert_eq "ab-tests file created" "true" "$([ -f "$AB_TESTS_FILE" ] && echo true || echo false)"
assert_eq "ab test original" "bug-fix" "$(jq -r '.tests[0].original' "$AB_TESTS_FILE")"
assert_eq "ab test variant" "bug-fix-v1" "$(jq -r '.tests[0].variant' "$AB_TESTS_FILE")"
assert_eq "ab test target_runs is 10" "10" "$(jq -r '.tests[0].target_runs' "$AB_TESTS_FILE")"

# Running auto again with same pair should not duplicate existing A/B test entry for that pair.
SCORES_DIR="$SCORES_DIR" \
TEMPLATES_DIR="$TEMPLATES_DIR" \
REGISTRY_FILE="$REGISTRY_FILE" \
REFINEMENT_LOG="$REFINEMENT_LOG" \
AB_TESTS_FILE="$AB_TESTS_FILE" \
bash "$REFINE_SCRIPT" --auto >/dev/null

pair_count="$(jq '[.tests[] | select(.original == "bug-fix" and .variant == "bug-fix-v1")] | length' "$AB_TESTS_FILE")"
assert_eq "ab test pair not duplicated" "1" "$pair_count"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
