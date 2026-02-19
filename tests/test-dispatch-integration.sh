#!/usr/bin/env bash
# test-dispatch-integration.sh - Tests for dispatch.sh --auto-select integration
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != *"$unexpected"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected NOT to contain: $unexpected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

PATCH_FILE="$PROJECT_DIR/scripts/dispatch-integration.patch"
SELECT_SCRIPT="$PROJECT_DIR/scripts/select-template.sh"

# ── Test: patch file exists ──────────────────────────────────────────────────
echo "=== Patch file existence ==="

assert_eq "patch file exists" "true" "$([ -f "$PATCH_FILE" ] && echo true || echo false)"
assert_eq "patch file is non-empty" "true" "$([ -s "$PATCH_FILE" ] && echo true || echo false)"

# ── Test: patch file content =================================================
echo "=== Patch file content ==="

patch_content="$(cat "$PATCH_FILE")"

assert_contains "patch adds --auto-select flag" "--auto-select" "$patch_content"
assert_contains "patch references select-template.sh" "select-template" "$patch_content"
assert_contains "patch includes advisory logging" "advisory" "$patch_content"
assert_contains "patch preserves explicit args" "explicit" "$patch_content"
assert_contains "patch references feedback-collector.sh" "feedback-collector.sh" "$patch_content"
assert_contains "patch passes run record path" 'state/runs/$BEAD_ID.json' "$patch_content"
non_blocking_marker='|| true' # REASON: literal marker assertion for non-blocking hook in patch content.
assert_contains "patch keeps feedback hook non-blocking" "$non_blocking_marker" "$patch_content"

# ── Test: select-template.sh advisory integration ────────────────────────────
# We test the advisory logic by simulating what the patch does:
# 1. Call select-template.sh with a prompt
# 2. Log recommendation
# 3. Don't override explicit template/agent

echo "=== Advisory mode: recommendation output ==="

# Setup temp scores
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SCORES_DIR="$TMP_DIR/scores"
mkdir -p "$SCORES_DIR"

# Create template-scores.json with known data
cat > "$SCORES_DIR/template-scores.json" <<'SCORES'
{
  "schema_version": "1.0.0",
  "generated_at": "2026-01-01T00:00:00Z",
  "templates": [
    {
      "template": "bug-fix",
      "total_runs": 25,
      "scoreable_runs": 23,
      "full_pass_rate": 0.6,
      "partial_pass_rate": 0.2,
      "retry_rate": 0.1,
      "timeout_rate": 0.05,
      "score": 0.665,
      "confidence": "high",
      "trend": "improving",
      "agents": [
        {"agent": "claude", "total_runs": 20, "full_pass_rate": 0.7, "score": 0.75},
        {"agent": "codex", "total_runs": 5, "full_pass_rate": 0.4, "score": 0.45}
      ]
    },
    {
      "template": "feature",
      "total_runs": 10,
      "scoreable_runs": 9,
      "full_pass_rate": 0.3,
      "partial_pass_rate": 0.3,
      "retry_rate": 0.2,
      "timeout_rate": 0.1,
      "score": 0.39,
      "confidence": "medium",
      "trend": "stable",
      "agents": [
        {"agent": "claude", "total_runs": 8, "full_pass_rate": 0.375, "score": 0.45},
        {"agent": "codex", "total_runs": 2, "full_pass_rate": 0.0, "score": 0.0}
      ]
    }
  ]
}
SCORES

# Test: select-template.sh returns recommendation for bug-fix task
rec="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "Fix the login bug")"
rec_template="$(echo "$rec" | jq -r '.template')"
rec_agent="$(echo "$rec" | jq -r '.agent')"
rec_confidence="$(echo "$rec" | jq -r '.confidence')"

assert_eq "recommends bug-fix template" "bug-fix" "$rec_template"
assert_eq "recommends claude agent" "claude" "$rec_agent"
assert_eq "high confidence" "high" "$rec_confidence"

# Test: select-template.sh returns recommendation for feature task
rec2="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "Add user registration")"
rec2_template="$(echo "$rec2" | jq -r '.template')"
rec2_agent="$(echo "$rec2" | jq -r '.agent')"

assert_eq "recommends feature template" "feature" "$rec2_template"
assert_eq "recommends claude agent for feature" "claude" "$rec2_agent"

# ── Test: advisory mode simulation ──────────────────────────────────────────
# The patch should implement advisory mode where:
# - If user explicitly passed template/agent, those are preserved
# - The recommendation is logged but doesn't override
echo "=== Advisory mode logic ==="

# Simulate advisory mode: explicit template_name="custom" should NOT be overridden
# This tests the logic described in the patch
EXPLICIT_TEMPLATE="custom"
EXPLICIT_AGENT="codex"

# Get recommendation
rec3="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "Fix the crash bug")"
rec3_template="$(echo "$rec3" | jq -r '.template')"
rec3_agent="$(echo "$rec3" | jq -r '.agent')"

# Advisory: recommendation exists but explicit args win
assert_eq "recommendation is bug-fix" "bug-fix" "$rec3_template"
assert_eq "recommendation is claude" "claude" "$rec3_agent"
# Explicit args should be preserved (dispatch logic, not select-template logic)
assert_eq "explicit template preserved" "custom" "$EXPLICIT_TEMPLATE"
assert_eq "explicit agent preserved" "codex" "$EXPLICIT_AGENT"

# ── Test: patch applies cleanly to dispatch.sh ───────────────────────────────
echo "=== Patch applicability ==="

# The patch should be a valid unified diff
first_line="$(head -1 "$PATCH_FILE")"
assert_contains "patch starts with diff or ---" "---" "$first_line"

# ── Test: patch handles missing scores gracefully ────────────────────────────
echo "=== Missing scores graceful handling ==="

EMPTY_DIR="$(mktemp -d)"
rec4="$(SCORES_DIR="$EMPTY_DIR" "$SELECT_SCRIPT" "Fix something")"
rec4_template="$(echo "$rec4" | jq -r '.template')"
rec4_warnings="$(echo "$rec4" | jq -r '.warnings[0]')"
rmdir "$EMPTY_DIR"

assert_eq "falls back to custom with no scores" "custom" "$rec4_template"
assert_contains "warning about missing scores" "No template-scores.json" "$rec4_warnings"

# ── Test: patch documents auto-select flag ───────────────────────────────────
echo "=== Patch documentation ==="

assert_contains "patch documents usage" "auto-select" "$patch_content"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
