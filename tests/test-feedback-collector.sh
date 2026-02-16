#!/usr/bin/env bash
# Tests for US-102: feedback-collector.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$PROJECT_DIR/scripts/feedback-collector.sh"
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

# --- Setup test fixtures ---

# Full pass run: status=done, exit_code=0, all verification pass
cat > "$TMPDIR/run-full-pass.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-aaa",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "do stuff",
  "prompt_hash": "abc123",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T10:05:00Z",
  "duration_seconds": 300,
  "status": "done",
  "attempt": 1,
  "exit_code": 0,
  "failure_reason": null,
  "template_name": "feature",
  "verification": {
    "lint": "pass",
    "tests": "pass",
    "ubs": "clean",
    "truthsayer": "pass",
    "truthsayer_errors": 0,
    "truthsayer_warnings": 0,
    "lint_details": null
  }
}
EOF

# Partial pass: done, exit_code=0, tests pass but lint fails
cat > "$TMPDIR/run-partial.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-bbb",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "fix thing",
  "prompt_hash": "def456",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T10:10:00Z",
  "duration_seconds": 600,
  "status": "done",
  "attempt": 1,
  "exit_code": 0,
  "failure_reason": null,
  "template_name": "bug-fix",
  "verification": {
    "lint": "fail",
    "tests": "pass",
    "ubs": "clean",
    "truthsayer": "pass",
    "lint_details": null
  }
}
EOF

# Agent failure: done, exit_code=1, tests fail
cat > "$TMPDIR/run-agent-fail.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-ccc",
  "agent": "claude",
  "model": "opus",
  "prompt": "add feature",
  "prompt_hash": "ghi789",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T10:08:00Z",
  "duration_seconds": 480,
  "status": "done",
  "attempt": 1,
  "exit_code": 1,
  "failure_reason": null,
  "template_name": "custom",
  "verification": {
    "lint": "fail",
    "tests": "fail",
    "ubs": "issues",
    "lint_details": null
  }
}
EOF

# Infra failure: tmux-launch-failed
cat > "$TMPDIR/run-infra.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-ddd",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "deploy",
  "prompt_hash": "jkl012",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T10:00:01Z",
  "duration_seconds": 0,
  "status": "failed",
  "attempt": 1,
  "exit_code": 1,
  "failure_reason": "tmux-launch-failed",
  "template_name": "custom",
  "verification": {
    "lint": "skipped",
    "tests": "skipped",
    "ubs": "clean",
    "lint_details": null
  }
}
EOF

# Timeout run
cat > "$TMPDIR/run-timeout.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-eee",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "big task",
  "prompt_hash": "mno345",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T11:00:05Z",
  "duration_seconds": 3605,
  "status": "timeout",
  "attempt": 2,
  "exit_code": null,
  "failure_reason": "watch-timeout-3600s",
  "template_name": "feature",
  "verification": {
    "lint": "pass",
    "tests": "skipped",
    "ubs": "clean",
    "lint_details": null
  }
}
EOF

# Retry run (attempt > 1, done)
cat > "$TMPDIR/run-retry.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-fff",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "retry task",
  "prompt_hash": "pqr678",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": "2026-02-13T10:03:00Z",
  "duration_seconds": 180,
  "status": "done",
  "attempt": 2,
  "exit_code": 0,
  "failure_reason": null,
  "template_name": "bug-fix",
  "verification": {
    "lint": "pass",
    "tests": "pass",
    "ubs": "clean",
    "truthsayer": "pass",
    "lint_details": null
  }
}
EOF

# Still running (no finished_at, no verification results)
cat > "$TMPDIR/run-running.json" <<'EOF'
{
  "schema_version": 1,
  "bead": "bd-ggg",
  "agent": "claude",
  "model": "sonnet",
  "prompt": "long task",
  "prompt_hash": "stu901",
  "started_at": "2026-02-13T10:00:00Z",
  "finished_at": null,
  "duration_seconds": null,
  "status": "running",
  "attempt": 1,
  "exit_code": null,
  "failure_reason": null,
  "template_name": "custom",
  "verification": null
}
EOF

# Set output dir
export FEEDBACK_DIR="$TMPDIR/feedback"
mkdir -p "$FEEDBACK_DIR"

# === Test 1: Script exists and is executable ===
echo "=== Test: Script exists ==="
assert_eq "feedback-collector.sh exists" "true" \
  "$([ -f "$COLLECTOR" ] && echo true || echo false)"
assert_eq "feedback-collector.sh is executable" "true" \
  "$([ -x "$COLLECTOR" ] && echo true || echo false)"

# === Test 2: Full pass classification ===
echo ""
echo "=== Test: Full pass ==="
"$COLLECTOR" "$TMPDIR/run-full-pass.json"
assert_eq "full pass output exists" "true" \
  "$([ -f "$FEEDBACK_DIR/bd-aaa.json" ] && echo true || echo false)"
assert_eq "full pass outcome" "full_pass" \
  "$(jq -r '.outcome' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass bead" "bd-aaa" \
  "$(jq -r '.bead' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass template" "feature" \
  "$(jq -r '.template' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass agent" "claude" \
  "$(jq -r '.agent' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass model" "sonnet" \
  "$(jq -r '.model' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass prompt_hash" "abc123" \
  "$(jq -r '.prompt_hash' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "full pass has schema_version" "true" \
  "$(jq 'has("schema_version")' "$FEEDBACK_DIR/bd-aaa.json")"

# === Test 3: Signal extraction ===
echo ""
echo "=== Test: Signal extraction (full pass) ==="
assert_eq "exit_clean=true" "true" \
  "$(jq '.signals.exit_clean' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "tests_pass=true" "true" \
  "$(jq '.signals.tests_pass' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "lint_pass=true" "true" \
  "$(jq '.signals.lint_pass' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "ubs_clean=true" "true" \
  "$(jq '.signals.ubs_clean' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "truthsayer_clean=true" "true" \
  "$(jq '.signals.truthsayer_clean' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "retried=false" "false" \
  "$(jq '.signals.retried' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "duration_ratio is number" "true" \
  "$(jq '.signals.duration_ratio | type == "number"' "$FEEDBACK_DIR/bd-aaa.json")"

# === Test 4: Partial pass ===
echo ""
echo "=== Test: Partial pass ==="
"$COLLECTOR" "$TMPDIR/run-partial.json"
assert_eq "partial pass outcome" "partial_pass" \
  "$(jq -r '.outcome' "$FEEDBACK_DIR/bd-bbb.json")"
assert_eq "partial lint_pass=false" "false" \
  "$(jq '.signals.lint_pass' "$FEEDBACK_DIR/bd-bbb.json")"
assert_eq "partial tests_pass=true" "true" \
  "$(jq '.signals.tests_pass' "$FEEDBACK_DIR/bd-bbb.json")"

# === Test 5: Agent failure ===
echo ""
echo "=== Test: Agent failure ==="
"$COLLECTOR" "$TMPDIR/run-agent-fail.json"
assert_eq "agent failure outcome" "agent_failure" \
  "$(jq -r '.outcome' "$FEEDBACK_DIR/bd-ccc.json")"
assert_eq "agent failure exit_clean=false" "false" \
  "$(jq '.signals.exit_clean' "$FEEDBACK_DIR/bd-ccc.json")"

# === Test 6: Infra failure ===
echo ""
echo "=== Test: Infra failure ==="
"$COLLECTOR" "$TMPDIR/run-infra.json"
assert_eq "infra failure outcome" "infra_failure" \
  "$(jq -r '.outcome' "$FEEDBACK_DIR/bd-ddd.json")"

# === Test 7: Timeout ===
echo ""
echo "=== Test: Timeout ==="
"$COLLECTOR" "$TMPDIR/run-timeout.json"
assert_eq "timeout outcome" "timeout" \
  "$(jq -r '.outcome' "$FEEDBACK_DIR/bd-eee.json")"
assert_eq "timeout retried=true" "true" \
  "$(jq '.signals.retried' "$FEEDBACK_DIR/bd-eee.json")"

# === Test 8: Retry detection ===
echo ""
echo "=== Test: Retry detection ==="
"$COLLECTOR" "$TMPDIR/run-retry.json"
assert_eq "retry retried=true" "true" \
  "$(jq '.signals.retried' "$FEEDBACK_DIR/bd-fff.json")"

# === Test 9: Running status skipped ===
echo ""
echo "=== Test: Running status ==="
"$COLLECTOR" "$TMPDIR/run-running.json"
assert_eq "running produces no output" "false" \
  "$([ -f "$FEEDBACK_DIR/bd-ggg.json" ] && echo true || echo false)"

# === Test 10: Failure patterns array present ===
echo ""
echo "=== Test: Failure patterns ==="
assert_eq "full pass has empty failure_patterns" "0" \
  "$(jq '.failure_patterns | length' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "failure_patterns is array" "true" \
  "$(jq '.failure_patterns | type == "array"' "$FEEDBACK_DIR/bd-aaa.json")"

# === Test 11: Timestamp present ===
echo ""
echo "=== Test: Timestamp ==="
assert_eq "has timestamp" "true" \
  "$(jq 'has("timestamp")' "$FEEDBACK_DIR/bd-aaa.json")"
assert_eq "timestamp is string" "true" \
  "$(jq '.timestamp | type == "string"' "$FEEDBACK_DIR/bd-aaa.json")"

# === Test 12: Output is valid JSON ===
echo ""
echo "=== Test: Valid JSON output ==="
for f in "$FEEDBACK_DIR"/*.json; do
  name="$(basename "$f")"
  if jq empty "$f" 2>/dev/null; then
    echo "  PASS: $name is valid JSON"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name is not valid JSON"
    FAIL=$((FAIL + 1))
  fi
done

# === Test 13: No args prints usage ===
echo ""
echo "=== Test: Usage message ==="
usage_output="$("$COLLECTOR" 2>&1 || true)"
assert_eq "no args shows usage" "true" \
  "$(echo "$usage_output" | grep -qi 'usage' && echo true || echo false)"

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
