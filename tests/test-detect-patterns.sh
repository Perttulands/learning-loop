#!/usr/bin/env bash
# Tests for US-103: detect-patterns.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECTOR="$PROJECT_DIR/scripts/detect-patterns.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

# === Test: Script exists and is executable ===
echo "=== Test: Script exists ==="
assert_eq "detect-patterns.sh exists" "true" \
  "$([ -f "$DETECTOR" ] && echo true || echo false)"
assert_eq "detect-patterns.sh is executable" "true" \
  "$([ -x "$DETECTOR" ] && echo true || echo false)"

# === Test: test-failure-after-completion ===
# Agent thinks it's done (exit_code=0, status=done) but tests fail
echo ""
echo "=== Test: test-failure-after-completion ==="
cat > "$TMPDIR/run-test-fail-after.json" <<'EOF'
{
  "bead": "bd-t01",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "pass", "tests": "fail", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-test-fail-after.json")"
assert_contains "detects test-failure-after-completion" "test-failure-after-completion" "$result"

# === Test: lint-failure-after-completion ===
echo ""
echo "=== Test: lint-failure-after-completion ==="
cat > "$TMPDIR/run-lint-fail-after.json" <<'EOF'
{
  "bead": "bd-t02",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "fail", "tests": "pass", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-lint-fail-after.json")"
assert_contains "detects lint-failure-after-completion" "lint-failure-after-completion" "$result"

# === Test: scope-creep (duration_ratio > 3.0) ===
echo ""
echo "=== Test: scope-creep ==="
cat > "$TMPDIR/run-scope-creep.json" <<'EOF'
{
  "bead": "bd-t03",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 2400,
  "verification": { "lint": "pass", "tests": "pass", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-scope-creep.json")"
assert_contains "detects scope-creep" "scope-creep" "$result"

# === Test: no scope-creep for normal duration ===
echo ""
echo "=== Test: no scope-creep for normal duration ==="
cat > "$TMPDIR/run-normal-dur.json" <<'EOF'
{
  "bead": "bd-t04",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "pass", "tests": "pass", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-normal-dur.json")"
assert_eq "no scope-creep for normal duration" "false" \
  "$(echo "$result" | grep -q "scope-creep" && echo true || echo false)"

# === Test: incomplete-work ===
# exit_code=0 but multiple verifications fail
echo ""
echo "=== Test: incomplete-work ==="
cat > "$TMPDIR/run-incomplete.json" <<'EOF'
{
  "bead": "bd-t05",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "fail", "tests": "fail", "ubs": "issues" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-incomplete.json")"
assert_contains "detects incomplete-work" "incomplete-work" "$result"

# === Test: infra-tmux ===
echo ""
echo "=== Test: infra-tmux ==="
cat > "$TMPDIR/run-infra-tmux.json" <<'EOF'
{
  "bead": "bd-t06",
  "status": "failed",
  "exit_code": 1,
  "failure_reason": "tmux-launch-failed",
  "attempt": 1,
  "duration_seconds": 0,
  "verification": { "lint": "skipped", "tests": "skipped", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-infra-tmux.json")"
assert_contains "detects infra-tmux" "infra-tmux" "$result"

# === Test: infra-disk ===
echo ""
echo "=== Test: infra-disk ==="
cat > "$TMPDIR/run-infra-disk.json" <<'EOF'
{
  "bead": "bd-t07",
  "status": "failed",
  "exit_code": 1,
  "failure_reason": "infra-disk-full",
  "attempt": 1,
  "duration_seconds": 10,
  "verification": { "lint": "skipped", "tests": "skipped", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-infra-disk.json")"
assert_contains "detects infra-disk" "infra-disk" "$result"

# === Test: repeated-failure ===
echo ""
echo "=== Test: repeated-failure ==="
cat > "$TMPDIR/run-repeated.json" <<'EOF'
{
  "bead": "bd-t08",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 3,
  "duration_seconds": 300,
  "verification": { "lint": "pass", "tests": "pass", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-repeated.json")"
assert_contains "detects repeated-failure" "repeated-failure" "$result"

# === Test: verification-gap ===
# Multiple verification checks are skipped
echo ""
echo "=== Test: verification-gap ==="
cat > "$TMPDIR/run-verif-gap.json" <<'EOF'
{
  "bead": "bd-t09",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "skipped", "tests": "skipped", "ubs": "clean" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-verif-gap.json")"
assert_contains "detects verification-gap" "verification-gap" "$result"

# === Test: no verification-gap when only one skipped ===
echo ""
echo "=== Test: no verification-gap with single skip ==="
cat > "$TMPDIR/run-one-skip.json" <<'EOF'
{
  "bead": "bd-t10",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "pass", "tests": "skipped", "ubs": "clean", "truthsayer": "pass" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-one-skip.json")"
assert_eq "no verification-gap for single skip" "false" \
  "$(echo "$result" | grep -q "verification-gap" && echo true || echo false)"

# === Test: clean run produces no patterns ===
echo ""
echo "=== Test: clean run = no patterns ==="
cat > "$TMPDIR/run-clean.json" <<'EOF'
{
  "bead": "bd-t11",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 1,
  "duration_seconds": 300,
  "verification": { "lint": "pass", "tests": "pass", "ubs": "clean", "truthsayer": "pass" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-clean.json")"
assert_eq "clean run has no patterns" "[]" "$result"

# === Test: multiple patterns detected at once ===
echo ""
echo "=== Test: multiple patterns ==="
cat > "$TMPDIR/run-multi.json" <<'EOF'
{
  "bead": "bd-t12",
  "status": "done",
  "exit_code": 0,
  "failure_reason": null,
  "attempt": 2,
  "duration_seconds": 2400,
  "verification": { "lint": "fail", "tests": "fail", "ubs": "issues" }
}
EOF
result="$("$DETECTOR" "$TMPDIR/run-multi.json")"
assert_contains "multi: test-failure-after-completion" "test-failure-after-completion" "$result"
assert_contains "multi: lint-failure-after-completion" "lint-failure-after-completion" "$result"
assert_contains "multi: scope-creep" "scope-creep" "$result"
assert_contains "multi: incomplete-work" "incomplete-work" "$result"
assert_contains "multi: repeated-failure" "repeated-failure" "$result"

# === Test: output is valid JSON array ===
echo ""
echo "=== Test: output format ==="
result="$("$DETECTOR" "$TMPDIR/run-multi.json")"
assert_eq "output is valid JSON array" "true" \
  "$(echo "$result" | jq 'type == "array"' 2>/dev/null || echo false)"

result_clean="$("$DETECTOR" "$TMPDIR/run-clean.json")"
assert_eq "clean output is valid JSON array" "true" \
  "$(echo "$result_clean" | jq 'type == "array"' 2>/dev/null || echo false)"

# === Test: pattern-registry.json ===
echo ""
echo "=== Test: pattern-registry ==="
export REGISTRY_FILE="$TMPDIR/pattern-registry.json"
"$DETECTOR" --update-registry "$TMPDIR/run-multi.json"
assert_eq "registry file created" "true" \
  "$([ -f "$REGISTRY_FILE" ] && echo true || echo false)"
assert_eq "registry is valid JSON" "true" \
  "$(jq empty "$REGISTRY_FILE" 2>/dev/null && echo true || echo false)"
assert_eq "registry has pattern entries" "true" \
  "$(jq 'length > 0' "$REGISTRY_FILE")"

# Run again to test accumulation
"$DETECTOR" --update-registry "$TMPDIR/run-infra-tmux.json"
assert_eq "registry accumulates count" "true" \
  "$(jq '."infra-tmux".count >= 1' "$REGISTRY_FILE")"

# === Test: usage message ===
echo ""
echo "=== Test: Usage ==="
usage_output="$("$DETECTOR" 2>&1 || true)"
assert_eq "no args shows usage" "true" \
  "$(echo "$usage_output" | grep -qi 'usage' && echo true || echo false)"

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
