#!/usr/bin/env bash
# Tests for refine-prompts.sh
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/refine-prompts.sh"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    echo "  in: $haystack"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc - file not found: $path"
  fi
}

assert_json_field() {
  local desc="$1" file="$2" query="$3" expected="$4"
  local actual
  actual="$(jq -r "$query" "$file" 2>/dev/null || echo "JQ_ERROR")"
  assert_eq "$desc" "$expected" "$actual"
}

setup() {
  TEST_DIR="$(mktemp -d)"
  export SCORES_DIR="$TEST_DIR/scores"
  export TEMPLATES_DIR="$TEST_DIR/templates"
  export FEEDBACK_DIR="$TEST_DIR/feedback"
  export REGISTRY_FILE="$TEST_DIR/feedback/pattern-registry.json"
  export REFINEMENT_LOG="$TEST_DIR/scores/refinement-log.json"
  mkdir -p "$SCORES_DIR" "$TEMPLATES_DIR" "$FEEDBACK_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: create template-scores.json with specific data
create_scores() {
  local template="$1" total_runs="$2" full_pass_rate="$3" trend="${4:-stable}"
  cat > "$SCORES_DIR/template-scores.json" <<EEOF
{
  "schema_version": "1.0.0",
  "generated_at": "2026-01-01T00:00:00Z",
  "templates": [
    {
      "template": "$template",
      "total_runs": $total_runs,
      "scoreable_runs": $total_runs,
      "full_pass_rate": $full_pass_rate,
      "partial_pass_rate": 0.3,
      "retry_rate": 0.1,
      "timeout_rate": 0.05,
      "score": $full_pass_rate,
      "confidence": "high",
      "trend": "$trend"
    }
  ]
}
EEOF
}

# Helper: create a template file
create_template() {
  local name="$1"
  cat > "$TEMPLATES_DIR/${name}.md" <<'EEOF'
# Template

You are a coding agent. Complete the task.

## Steps
1. Read the code
2. Make changes
3. Run tests
EEOF
}

# Helper: create pattern registry
create_registry() {
  local pattern="$1" count="$2"
  cat > "$REGISTRY_FILE" <<EEOF
{
  "$pattern": {
    "count": $count,
    "first_seen": "2026-01-01T00:00:00Z",
    "last_seen": "2026-01-15T00:00:00Z",
    "last_beads": ["bd-abc"]
  }
}
EEOF
}

# Helper: create registry with multiple patterns
create_multi_registry() {
  cat > "$REGISTRY_FILE" <<'EEOF'
{
  "test-failure-after-completion": {
    "count": 10,
    "first_seen": "2026-01-01T00:00:00Z",
    "last_seen": "2026-01-15T00:00:00Z",
    "last_beads": ["bd-abc"]
  },
  "lint-failure-after-completion": {
    "count": 8,
    "first_seen": "2026-01-01T00:00:00Z",
    "last_seen": "2026-01-15T00:00:00Z",
    "last_beads": ["bd-def"]
  }
}
EEOF
}

# Helper: create feedback records for a template
create_feedback_records() {
  local template="$1" count="$2" outcome="${3:-partial_pass}"
  for i in $(seq 1 "$count"); do
    cat > "$FEEDBACK_DIR/test-$template-$i.json" <<EEOF
{
  "bead": "test-$template-$i",
  "timestamp": "2026-01-${i}T00:00:00Z",
  "template": "$template",
  "agent": "claude",
  "model": "opus",
  "outcome": "$outcome",
  "signals": {"exit_clean": true, "tests_pass": false, "lint_pass": true, "ubs_clean": true, "truthsayer_clean": true, "duration_ratio": 0.5, "retried": false},
  "failure_patterns": ["test-failure-after-completion"],
  "prompt_hash": "hash$i",
  "schema_version": "1.0.0"
}
EEOF
  done
}

# ---- Tests ----

# Test 1: Usage message
setup
output="$(bash "$SCRIPT" --help 2>&1 || true)"
assert_contains "usage message shown" "Usage" "$output"
teardown

# Test 2: No scores file - exits cleanly
setup
output="$(bash "$SCRIPT" 2>&1 || true)"
assert_contains "no scores file message" "No template-scores" "$output"
teardown

# Test 3: No templates needing refinement (pass rate above threshold)
setup
create_scores "custom" 15 0.80 "stable"
create_template "custom"
output="$(bash "$SCRIPT" 2>&1)"
assert_contains "no refinement needed" "No templates need refinement" "$output"
teardown

# Test 4: Trigger on low pass rate (< 0.50 with >= 10 runs)
setup
create_scores "bug-fix" 12 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
output="$(bash "$SCRIPT" --dry-run 2>&1)"
assert_contains "low pass rate trigger" "bug-fix" "$output"
assert_contains "dry run no file created" "dry-run" "$output"
teardown

# Test 5: Does not trigger with < 10 runs
setup
create_scores "bug-fix" 5 0.20 "stable"
create_template "bug-fix"
output="$(bash "$SCRIPT" 2>&1)"
assert_contains "insufficient runs skip" "No templates need refinement" "$output"
teardown

# Test 6: Trigger on pattern count >= 5
setup
create_scores "feature" 15 0.55 "stable"
create_template "feature"
create_registry "test-failure-after-completion" 7
output="$(bash "$SCRIPT" --dry-run 2>&1)"
assert_contains "pattern count trigger" "feature" "$output"
teardown

# Test 7: Trigger on declining trend (2+ cycles - use declining trend)
setup
create_scores "refactor" 15 0.55 "declining"
create_template "refactor"
output="$(bash "$SCRIPT" --dry-run 2>&1)"
assert_contains "declining trend trigger" "refactor" "$output"
teardown

# Test 8: --auto flag generates variant file
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
assert_eq "variant file created" "1" "${#variants[@]}"
teardown

# Test 9: Variant file has content
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  assert_contains "variant has original content" "coding agent" "$content"
  assert_contains "variant has refinement addition" "test" "$content"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: variant has content - no variant file found"
fi
teardown

# Test 10: Variant naming increments (v1, v2, ...)
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
# Create v1 first
cp "$TEMPLATES_DIR/bug-fix.md" "$TEMPLATES_DIR/bug-fix-v1.md"
bash "$SCRIPT" --auto > /dev/null 2>&1
assert_file_exists "v2 created when v1 exists" "$TEMPLATES_DIR/bug-fix-v2.md"
teardown

# Test 11: --dry-run does NOT create files
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --dry-run > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
assert_eq "dry-run creates no files" "0" "${#variants[@]}"
teardown

# Test 12: Refinement log is written (--auto)
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
assert_file_exists "refinement log created" "$REFINEMENT_LOG"
teardown

# Test 13: Refinement log has correct structure
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
assert_json_field "log has entries array" "$REFINEMENT_LOG" '.entries | length' "1"
assert_json_field "log entry has template" "$REFINEMENT_LOG" '.entries[0].template' "bug-fix"
assert_json_field "log entry has variant" "$REFINEMENT_LOG" '.entries[0].variant' "bug-fix-v1"
assert_json_field "log entry has trigger" "$REFINEMENT_LOG" '.entries[0].trigger' "low_pass_rate"
teardown

# Test 14: Refinement strategy for test-failure-after-completion
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 10
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  # Should add test-related instructions
  assert_contains "test failure strategy adds test instruction" "test" "$content"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: test failure strategy - no variant file found"
fi
teardown

# Test 15: Refinement strategy for lint-failure-after-completion
setup
create_scores "feature" 15 0.30 "stable"
create_template "feature"
create_registry "lint-failure-after-completion" 10
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/feature-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  assert_contains "lint failure strategy adds lint instruction" "lint" "$content"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: lint failure strategy - no variant file found"
fi
teardown

# Test 16: Refinement strategy for scope-creep
setup
create_scores "feature" 15 0.30 "stable"
create_template "feature"
create_registry "scope-creep" 10
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/feature-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  assert_contains "scope creep strategy adds scope instruction" "scope" "$content"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: scope creep strategy - no variant file found"
fi
teardown

# Test 17: Refinement strategy for incomplete-work
setup
create_scores "feature" 15 0.30 "stable"
create_template "feature"
create_registry "incomplete-work" 10
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/feature-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  assert_contains "incomplete work strategy adds completion instruction" "complete" "$content"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: incomplete work strategy - no variant file found"
fi
teardown

# Test 18: Multiple patterns - applies all relevant strategies
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_multi_registry
bash "$SCRIPT" --auto > /dev/null 2>&1
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
if [[ ${#variants[@]} -gt 0 ]]; then
  content="$(cat "${variants[0]}")"
  assert_contains "multi pattern has test instruction" "test" "$content"
  assert_contains "multi pattern has lint instruction" "lint" "$content"
else
  FAIL=$((FAIL + 1))
  FAIL=$((FAIL + 1))
  echo "FAIL: multi pattern - no variant file found"
fi
teardown

# Test 19: Template not found on disk - skipped gracefully
setup
create_scores "nonexistent" 15 0.30 "stable"
create_registry "test-failure-after-completion" 10
output="$(bash "$SCRIPT" --auto 2>&1)"
assert_contains "missing template warning" "not found" "$output"
teardown

# Test 20: Refinement log accumulates entries
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
# Run twice
bash "$SCRIPT" --auto > /dev/null 2>&1
# Update scores to still trigger
create_scores "bug-fix" 15 0.25 "stable"
bash "$SCRIPT" --auto > /dev/null 2>&1
log_entries="$(jq '.entries | length' "$REFINEMENT_LOG")"
assert_eq "log accumulates entries" "2" "$log_entries"
teardown

# Test 21: Default mode (no --auto, no --dry-run) shows what would be done
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
output="$(bash "$SCRIPT" 2>&1)"
assert_contains "default mode is preview" "Would refine" "$output"
shopt -s nullglob
variants=("$TEMPLATES_DIR"/bug-fix-v*.md)
shopt -u nullglob
assert_eq "default mode no files" "0" "${#variants[@]}"
teardown

# Test 22: Refinement log entry has timestamp
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
ts="$(jq -r '.entries[0].timestamp' "$REFINEMENT_LOG")"
assert_contains "log entry has ISO timestamp" "2026" "$ts"
teardown

# Test 23: Refinement log entry has patterns applied
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_multi_registry
bash "$SCRIPT" --auto > /dev/null 2>&1
patterns_count="$(jq '.entries[0].patterns_applied | length' "$REFINEMENT_LOG")"
assert_eq "log entry has patterns applied" "2" "$patterns_count"
teardown

# Test 24: Score data included in log
setup
create_scores "bug-fix" 15 0.30 "stable"
create_template "bug-fix"
create_registry "test-failure-after-completion" 6
bash "$SCRIPT" --auto > /dev/null 2>&1
fpr="$(jq '.entries[0].full_pass_rate' "$REFINEMENT_LOG")"
# Compare as numbers (jq may output 0.3 or 0.30)
assert_eq "log has full_pass_rate" "1" "$(echo "$fpr" | awk '{print ($1 >= 0.29 && $1 <= 0.31) ? 1 : 0}')"
assert_json_field "log has total_runs" "$REFINEMENT_LOG" '.entries[0].total_runs' "15"
teardown

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
