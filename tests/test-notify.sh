#!/usr/bin/env bash
# Tests for scripts/notify.sh — notification wrapper for learning loop events
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTIFY="$PROJECT_DIR/scripts/notify.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    echo "  actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected NOT to contain: $needle"
    echo "  actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a mock wake-gateway.sh that logs calls
MOCK_GATEWAY="$TMP_DIR/wake-gateway.sh"
cat > "$MOCK_GATEWAY" << 'MOCK'
#!/usr/bin/env bash
echo "$1" >> "$(dirname "$0")/gateway-calls.log"
echo '{"status":"ok"}'
MOCK
chmod +x "$MOCK_GATEWAY"
GATEWAY_LOG="$TMP_DIR/gateway-calls.log"

# --- Test: script exists and is executable ---
assert_eq "notify.sh exists" "true" "$(test -f "$NOTIFY" && echo true || echo false)"
assert_eq "notify.sh is executable" "true" "$(test -x "$NOTIFY" && echo true || echo false)"

# --- Test: usage ---
output="$(WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" --help 2>&1)"
assert_contains "usage shows event types" "variant-created" "$output"
assert_contains "usage shows event types" "variant-promoted" "$output"
assert_contains "usage shows score-regression" "score-regression" "$output"
assert_contains "usage shows weekly-report" "weekly-report" "$output"

# --- Test: no args shows usage ---
output="$("$NOTIFY" 2>&1 || true)"
assert_contains "no args shows usage" "Usage" "$output"

# --- Test: variant-created event ---
rm -f "$GATEWAY_LOG"
output="$(WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" variant-created --template bug-fix --variant bug-fix-v2 --trigger low_pass_rate --pass-rate 0.35 2>&1)"
assert_eq "variant-created exits 0" "0" "$?"
msg="$(cat "$GATEWAY_LOG")"
assert_contains "variant-created mentions template" "bug-fix" "$msg"
assert_contains "variant-created mentions variant" "bug-fix-v2" "$msg"
assert_contains "variant-created mentions trigger" "low_pass_rate" "$msg"
assert_contains "variant-created mentions Learning Loop" "Learning Loop" "$msg"

# --- Test: variant-promoted event ---
rm -f "$GATEWAY_LOG"
WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" variant-promoted --variant bug-fix-v2 --original bug-fix --variant-score 0.8 --original-score 0.6
msg="$(cat "$GATEWAY_LOG")"
assert_contains "variant-promoted mentions variant" "bug-fix-v2" "$msg"
assert_contains "variant-promoted mentions original" "bug-fix" "$msg"
assert_contains "variant-promoted mentions promoted" "romoted" "$msg"

# --- Test: variant-discarded event ---
rm -f "$GATEWAY_LOG"
WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" variant-discarded --variant bug-fix-v2 --original bug-fix --variant-score 0.5 --original-score 0.6
msg="$(cat "$GATEWAY_LOG")"
assert_contains "variant-discarded mentions variant" "bug-fix-v2" "$msg"
assert_contains "variant-discarded mentions discarded" "iscarded" "$msg"

# --- Test: score-regression event ---
rm -f "$GATEWAY_LOG"
WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" score-regression --template feature --old-score 0.8 --new-score 0.5
msg="$(cat "$GATEWAY_LOG")"
assert_contains "score-regression mentions template" "feature" "$msg"
assert_contains "score-regression mentions regression" "egression" "$msg"
assert_contains "score-regression mentions scores" "0.8" "$msg"
assert_contains "score-regression mentions new score" "0.5" "$msg"

# --- Test: weekly-report event ---
rm -f "$GATEWAY_LOG"
WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" weekly-report --summary "Weekly Report (2026-W07): 50 runs, 3 templates improving."
msg="$(cat "$GATEWAY_LOG")"
assert_contains "weekly-report mentions summary" "Weekly Report" "$msg"
assert_contains "weekly-report mentions Learning Loop" "Learning Loop" "$msg"

# --- Test: unknown event type ---
output="$(WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" unknown-event 2>&1 || true)"
assert_contains "unknown event shows error" "Unknown event" "$output"

# --- Test: --dry-run does not call gateway ---
rm -f "$GATEWAY_LOG"
output="$(WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" variant-created --template bug-fix --variant bug-fix-v2 --trigger low_pass_rate --pass-rate 0.35 --dry-run 2>&1)"
assert_eq "dry-run does not call gateway" "false" "$(test -f "$GATEWAY_LOG" && echo true || echo false)"
assert_contains "dry-run shows message" "bug-fix" "$output"

# --- Test: gateway failure does not crash script ---
FAIL_GATEWAY="$TMP_DIR/fail-gateway.sh"
cat > "$FAIL_GATEWAY" << 'FMOCK'
#!/usr/bin/env bash
echo "wake failed: connection refused" >&2
exit 1
FMOCK
chmod +x "$FAIL_GATEWAY"
output="$(WAKE_GATEWAY="$FAIL_GATEWAY" "$NOTIFY" weekly-report --summary "test" 2>&1 || true)"
# Should not crash (exit code 0), just warn
assert_contains "gateway failure warns" "Warning" "$output"

# --- Test: NOTIFY_ENABLED=false skips notification ---
rm -f "$GATEWAY_LOG"
NOTIFY_ENABLED=false WAKE_GATEWAY="$MOCK_GATEWAY" "$NOTIFY" variant-created --template t --variant v --trigger tr --pass-rate 0.1
assert_eq "NOTIFY_ENABLED=false skips gateway" "false" "$(test -f "$GATEWAY_LOG" && echo true || echo false)"

# --- Summary ---
echo ""
echo "test-notify.sh: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
