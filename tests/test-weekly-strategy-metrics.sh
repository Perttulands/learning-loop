#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/weekly-strategy.sh"

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

assert_near() {
  local desc="$1" expected="$2" actual="$3" tolerance="${4:-0.01}"
  local diff
  diff="$(echo "$expected - $actual" | bc -l | tr -d '-')"
  if echo "$diff <= $tolerance" | bc -l | grep -q '^1'; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected: $expected (+/- $tolerance)"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCORES_DIR="$TMPDIR_BASE/scores"
FEEDBACK_DIR="$TMPDIR_BASE/feedback"
REPORTS_DIR="$TMPDIR_BASE/reports"
mkdir -p "$SCORES_DIR" "$FEEDBACK_DIR" "$REPORTS_DIR"

cat > "$SCORES_DIR/template-scores.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-20T00:00:00Z",
  "templates": [
    {
      "template": "feature",
      "total_runs": 10,
      "scoreable_runs": 8,
      "full_pass_rate": 0.5,
      "partial_pass_rate": 0.25,
      "retry_rate": 0.1,
      "timeout_rate": 0.1,
      "score": 0.57,
      "confidence": "medium",
      "trend": "stable",
      "agents": []
    },
    {
      "template": "bug-fix",
      "total_runs": 20,
      "scoreable_runs": 18,
      "full_pass_rate": 0.7,
      "partial_pass_rate": 0.1,
      "retry_rate": 0.05,
      "timeout_rate": 0.05,
      "score": 0.73,
      "confidence": "high",
      "trend": "improving",
      "agents": []
    }
  ]
}
JSON

cat > "$SCORES_DIR/ab-tests.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "tests": [
    {"original":"feature","variant":"feature-v1","status":"active","target_runs":10,"original_runs":3,"variant_runs":3},
    {"original":"bug-fix","variant":"bug-fix-v1","status":"completed","target_runs":10,"original_runs":10,"variant_runs":10}
  ]
}
JSON

cat > "$SCORES_DIR/refinement-log.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "entries": [
    {"template":"feature","variant":"feature-v1","trigger":"low_pass_rate","timestamp":"2026-02-20T00:00:00Z"}
  ]
}
JSON

SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT" >/dev/null

report_file="$(ls -1 "$REPORTS_DIR"/strategy-*.json | head -n 1)"

assert_eq "report created" "true" "$([[ -f "$report_file" ]] && echo true || echo false)"
assert_eq "metrics total_templates" "2" "$(jq -r '.metrics.total_templates' "$report_file")"
assert_eq "metrics total_runs" "30" "$(jq -r '.metrics.total_runs' "$report_file")"
assert_eq "metrics scoreable_runs" "26" "$(jq -r '.metrics.scoreable_runs' "$report_file")"
assert_eq "metrics active_ab_tests" "1" "$(jq -r '.metrics.active_ab_tests' "$report_file")"
assert_eq "metrics completed_ab_tests" "1" "$(jq -r '.metrics.completed_ab_tests' "$report_file")"
assert_eq "metrics refinements_logged" "1" "$(jq -r '.metrics.refinements_logged' "$report_file")"
assert_near "metrics avg_template_score" "0.65" "$(jq -r '.metrics.avg_template_score' "$report_file")" "0.01"
assert_near "metrics overall_full_pass_rate" "0.638" "$(jq -r '.metrics.overall_full_pass_rate' "$report_file")" "0.01"
assert_eq "highlights array present" "array" "$(jq -r '.highlights | type' "$report_file")"
assert_eq "highlights count" "4" "$(jq -r '.highlights | length' "$report_file")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
