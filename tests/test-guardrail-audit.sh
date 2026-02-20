#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/guardrail-audit.sh"

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

# Minimal files so guardrail checks have readable inputs
cat > "$SCORES_DIR/ab-tests.json" <<'JSON'
{"schema_version":"1.0.0","tests":[]}
JSON
cat > "$SCORES_DIR/refinement-log.json" <<'JSON'
{"schema_version":"1.0.0","entries":[]}
JSON
cat > "$SCORES_DIR/template-scores.json" <<'JSON'
{"schema_version":"1.0.0","templates":[]}
JSON

out="$(SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" REPORTS_DIR="$REPORTS_DIR" "$SCRIPT")"
report_file="$(ls -1 "$REPORTS_DIR"/guardrail-audit-*.json | head -n 1)"

assert_eq "audit command reports output path" "true" "$(echo "$out" | grep -q 'guardrail-audit' && echo true || echo false)"
assert_eq "report file created" "true" "$([ -f "$report_file" ] && echo true || echo false)"
assert_eq "report is valid json" "0" "$(jq empty "$report_file" >/dev/null 2>&1; echo $?)"
assert_eq "report has six checks" "6" "$(jq -r '.checks | length' "$report_file")"
assert_eq "report has variant_limit check" "true" "$(jq '.checks | map(.id) | index("variant_limit") != null' "$report_file")"
assert_eq "report has duplicate_detection check" "true" "$(jq '.checks | map(.id) | index("duplicate_detection") != null' "$report_file")"


echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
