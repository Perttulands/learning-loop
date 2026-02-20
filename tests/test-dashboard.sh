#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/dashboard.sh"

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
REPORTS_DIR="$TMPDIR_BASE/reports"
mkdir -p "$SCORES_DIR" "$REPORTS_DIR"

cat > "$SCORES_DIR/template-scores.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-20T00:00:00Z",
  "templates": [
    {
      "template": "bug-fix",
      "total_runs": 12,
      "scoreable_runs": 10,
      "full_pass_rate": 0.6,
      "partial_pass_rate": 0.2,
      "retry_rate": 0.1,
      "timeout_rate": 0.1,
      "score": 0.62,
      "trend": "improving"
    }
  ]
}
JSON

cat > "$SCORES_DIR/agent-scores.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-02-20T00:00:00Z",
  "agents": [
    {
      "agent": "claude",
      "total_runs": 12,
      "pass_rate": 0.6,
      "score": 0.62
    }
  ]
}
JSON

cat > "$SCORES_DIR/ab-tests.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "tests": [
    {
      "original": "bug-fix",
      "variant": "bug-fix-v1",
      "status": "active",
      "target_runs": 10,
      "original_runs": 5,
      "variant_runs": 4
    }
  ]
}
JSON

cat > "$REPORTS_DIR/strategy-2026-W07.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "summary": "Weekly Strategy Report (2026-W07): steady improvements.",
  "recommendations": [
    "Refine bug-fix template.",
    "Increase A/B sample size."
  ]
}
JSON

out="$(SCORES_DIR="$SCORES_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT")"
html_file="$REPORTS_DIR/dashboard.html"

assert_eq "dashboard command reports output" "true" "$(echo "$out" | grep -q 'dashboard.html' && echo true || echo false)"
assert_eq "dashboard file exists" "true" "$([ -f "$html_file" ] && echo true || echo false)"
assert_eq "dashboard has title" "true" "$(grep -q 'Learning Loop Dashboard' "$html_file" && echo true || echo false)"
assert_eq "dashboard includes template name" "true" "$(grep -q 'bug-fix' "$html_file" && echo true || echo false)"
assert_eq "dashboard includes agent name" "true" "$(grep -q 'claude' "$html_file" && echo true || echo false)"
assert_eq "dashboard includes recommendation" "true" "$(grep -q 'Refine bug-fix template' "$html_file" && echo true || echo false)"


echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
