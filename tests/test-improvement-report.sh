#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_SCRIPT="$PROJECT_DIR/scripts/improvement-report.py"
LOOP_BIN="$PROJECT_DIR/loop"

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    FAIL=$((FAIL + 1))
  fi
}

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

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FILLED_DB="$TMPDIR/filled.db"
EMPTY_DB="$TMPDIR/empty.db"

"$LOOP_BIN" --db "$FILLED_DB" init >/dev/null
"$LOOP_BIN" --db "$EMPTY_DB" init >/dev/null

cat > "$TMPDIR/run-1.json" <<'JSON'
{"id":"run-1","task":"fix auth middleware","outcome":"success","duration_seconds":120,"timestamp":"2026-03-01T10:00:00Z","tests_passed":true,"lint_passed":true,"agent":"codex","model":"gpt-5","metadata":{"template":"bug-fix"}}
JSON

cat > "$TMPDIR/run-2.json" <<'JSON'
{"id":"run-2","task":"fix auth middleware follow-up","outcome":"failure","duration_seconds":180,"timestamp":"2026-03-02T10:00:00Z","tests_passed":false,"lint_passed":true,"agent":"codex","model":"gpt-5","metadata":{"template":"bug-fix"}}
JSON

cat > "$TMPDIR/run-3.json" <<'JSON'
{"id":"run-3","task":"stabilize auth tests","outcome":"success","duration_seconds":90,"timestamp":"2026-03-03T10:00:00Z","tests_passed":true,"lint_passed":true,"agent":"codex","model":"gpt-5","metadata":{"template":"bug-fix"}}
JSON

cat > "$TMPDIR/run-4.json" <<'JSON'
{"id":"run-4","task":"repair flaky auth tests","outcome":"success","duration_seconds":60,"timestamp":"2026-03-05T10:00:00Z","tests_passed":true,"lint_passed":true,"agent":"codex","model":"gpt-5","metadata":{"template":"bug-fix"}}
JSON

for run_file in "$TMPDIR"/run-*.json; do
  "$LOOP_BIN" --db "$FILLED_DB" ingest "$run_file" >/dev/null
done

filled_output="$(python3 "$REPORT_SCRIPT" --db "$FILLED_DB")"
empty_output="$(python3 "$REPORT_SCRIPT" --db "$EMPTY_DB")"

assert_eq "report script exists" "true" "$([[ -f "$REPORT_SCRIPT" ]] && echo true || echo false)"
assert_contains "filled report header" "Learning Loop Improvement Report" "$filled_output"
assert_contains "filled report metric 1" "Metric 1: Run Success Rate" "$filled_output"
assert_contains "filled report dates include first point" "2026-03-01" "$filled_output"
assert_contains "filled report dates include second point" "2026-03-02" "$filled_output"
assert_contains "filled report dates include third point" "2026-03-03" "$filled_output"
assert_contains "filled report includes weekly snapshots" "Weekly snapshots:" "$filled_output"
assert_contains "filled report includes duration metric" "Metric 2: Time To Successful Completion" "$filled_output"
assert_contains "filled report includes pattern metric" "Metric 3: Failure Pattern Recurrence Rate" "$filled_output"
assert_contains "filled report includes detected pattern" "tests-failed" "$filled_output"
assert_contains "filled report uses sparse-data warning" "insufficient volume to call improvement" "$filled_output"
assert_contains "empty report says no data yet" "Status: no data yet" "$empty_output"
assert_contains "empty report references checked databases" "Checked databases:" "$empty_output"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
