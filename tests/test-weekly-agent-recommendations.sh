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
    {"template":"feature","total_runs":10,"scoreable_runs":10,"full_pass_rate":0.8,"partial_pass_rate":0.1,"retry_rate":0.1,"timeout_rate":0,"score":0.81,"confidence":"high","trend":"improving"}
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
      "total_runs": 20,
      "pass_rate": 0.7,
      "score": 0.72,
      "avg_duration_ratio": 0.7,
      "top_failure_patterns": [],
      "templates": [
        {"template": "feature", "total_runs": 10, "score": 0.85, "full_pass_rate": 0.8},
        {"template": "refactor", "total_runs": 10, "score": 0.55, "full_pass_rate": 0.5}
      ]
    }
  ]
}
JSON

SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT" >/dev/null

report_file="$(ls -1 "$REPORTS_DIR"/strategy-*.json | head -n 1)"
assert_eq "report created" "true" "$([ -f "$report_file" ] && echo true || echo false)"
assert_eq "agent recommendations section exists" "array" "$(jq -r '.agent_recommendations | type' "$report_file")"
assert_eq "agent recommendation has claude" "claude" "$(jq -r '.agent_recommendations[0].agent' "$report_file")"
assert_eq "agent strength template" "feature" "$(jq -r '.agent_recommendations[0].strengths[0].template' "$report_file")"
assert_eq "agent weakness template" "refactor" "$(jq -r '.agent_recommendations[0].weaknesses[0].template' "$report_file")"
assert_eq "recommendation mentions excels" "true" "$(jq -r '.agent_recommendations[0].recommendation | contains("excels on feature")' "$report_file")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
