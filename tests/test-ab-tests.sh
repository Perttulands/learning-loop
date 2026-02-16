#!/usr/bin/env bash
# Tests for scripts/ab-tests.sh - A/B test lifecycle management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AB_SCRIPT="$PROJECT_DIR/scripts/ab-tests.sh"

PASS=0
FAIL=0

assert() {
  local desc="$1" result="$2" expected="$3"
  if [[ "$result" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  got:      $result"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" result="$2" expected="$3"
  if echo "$result" | grep -qF "$expected"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected to contain: $expected"
    echo "  got: $result"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local desc="$1" json="$2" field="$3" expected="$4"
  local actual
  actual="$(echo "$json" | jq -r "$field")"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  field: $field"
    echo "  expected: $expected"
    echo "  got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_num() {
  local desc="$1" json="$2" field="$3" op="$4" expected="$5"
  local actual
  actual="$(echo "$json" | jq "$field")"
  if echo "$actual $op $expected" | bc -l | grep -q '^1'; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  field: $field ($actual $op $expected)"
    FAIL=$((FAIL + 1))
  fi
}

# Setup temp directory
setup() {
  TMPDIR="$(mktemp -d)"
  export SCORES_DIR="$TMPDIR/scores"
  export TEMPLATES_DIR="$TMPDIR/templates"
  export FEEDBACK_DIR="$TMPDIR/feedback"
  export AB_TESTS_FILE="$SCORES_DIR/ab-tests.json"
  export REFINEMENT_LOG="$SCORES_DIR/refinement-log.json"
  mkdir -p "$SCORES_DIR" "$TEMPLATES_DIR" "$FEEDBACK_DIR" "$TEMPLATES_DIR/.archive"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Helper: create a template file
create_template() {
  local name="$1"
  echo "# Template: $name" > "$TEMPLATES_DIR/${name}.md"
}

# Helper: create a variant template file
create_variant() {
  local base="$1" version="$2"
  echo "# Template: ${base}-v${version}" > "$TEMPLATES_DIR/${base}-v${version}.md"
}

# Helper: create feedback records for a template
create_feedback() {
  local bead="$1" template="$2" outcome="$3"
  jq -n --arg b "$bead" --arg t "$template" --arg o "$outcome" \
    '{bead: $b, template: $t, outcome: $o, agent: "claude", model: "opus",
     signals: {retried: false, duration_ratio: 1.0},
     failure_patterns: [], timestamp: "2026-01-15T00:00:00Z"}' \
    > "$FEEDBACK_DIR/${bead}.json"
}

# Helper: create template-scores with specific data
create_scores() {
  local template="$1" score="$2" total="$3" pass_rate="$4"
  jq -n --arg t "$template" --argjson s "$score" --argjson n "$total" --argjson pr "$pass_rate" \
    '{schema_version: "1.0.0", generated_at: "2026-01-15T00:00:00Z",
     templates: [{
       template: $t, total_runs: $n, scoreable_runs: $n,
       full_pass_rate: $pr, partial_pass_rate: 0, retry_rate: 0, timeout_rate: 0,
       score: $s, confidence: "medium", trend: "stable",
       agents: [{agent: "claude", total_runs: $n, full_pass_rate: $pr, score: $s}]
     }]}' > "$SCORES_DIR/template-scores.json"
}

# Helper: create scores with two templates
create_two_scores() {
  local t1="$1" s1="$2" n1="$3" pr1="$4" t2="$5" s2="$6" n2="$7" pr2="$8"
  jq -n --arg t1 "$t1" --argjson s1 "$s1" --argjson n1 "$n1" --argjson pr1 "$pr1" \
        --arg t2 "$t2" --argjson s2 "$s2" --argjson n2 "$n2" --argjson pr2 "$pr2" \
    '{schema_version: "1.0.0", generated_at: "2026-01-15T00:00:00Z",
     templates: [
       {template: $t1, total_runs: $n1, scoreable_runs: $n1,
        full_pass_rate: $pr1, partial_pass_rate: 0, retry_rate: 0, timeout_rate: 0,
        score: $s1, confidence: "medium", trend: "stable",
        agents: [{agent: "claude", total_runs: $n1, full_pass_rate: $pr1, score: $s1}]},
       {template: $t2, total_runs: $n2, scoreable_runs: $n2,
        full_pass_rate: $pr2, partial_pass_rate: 0, retry_rate: 0, timeout_rate: 0,
        score: $s2, confidence: "medium", trend: "stable",
        agents: [{agent: "claude", total_runs: $n2, full_pass_rate: $pr2, score: $s2}]}
     ]}' > "$SCORES_DIR/template-scores.json"
}

# =========================================
# Test: usage message
# =========================================
setup
out="$("$AB_SCRIPT" --help 2>&1 || true)"
assert_contains "help shows usage" "$out" "Usage"
teardown

# =========================================
# Test: usage without subcommand
# =========================================
setup
out="$("$AB_SCRIPT" 2>&1 || true)"
assert_contains "no subcommand shows usage" "$out" "Usage"
teardown

# =========================================
# Test: create subcommand creates a new A/B test
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
out="$("$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1)"
assert "create exits 0" "$?" "0"
assert "ab-tests.json exists" "$(test -f "$AB_TESTS_FILE" && echo yes)" "yes"
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "has schema_version" "$ab_data" ".schema_version" "1.0.0"
assert_json_field "test has original" "$ab_data" ".tests[0].original" "bug-fix"
assert_json_field "test has variant" "$ab_data" ".tests[0].variant" "bug-fix-v1"
assert_json_field "test has status active" "$ab_data" ".tests[0].status" "active"
assert_json_field "test has target_runs" "$ab_data" ".tests[0].target_runs" "10"
assert_json_field "original runs start at 0" "$ab_data" ".tests[0].original_runs" "0"
assert_json_field "variant runs start at 0" "$ab_data" ".tests[0].variant_runs" "0"
teardown

# =========================================
# Test: create with custom target_runs
# =========================================
setup
create_template "feature"
create_variant "feature" 1
"$AB_SCRIPT" create feature feature-v1 --target-runs 20 2>&1
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "custom target_runs" "$ab_data" ".tests[0].target_runs" "20"
teardown

# =========================================
# Test: create appends to existing tests
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_template "feature"
create_variant "feature" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
"$AB_SCRIPT" create feature feature-v1 2>&1
ab_data="$(cat "$AB_TESTS_FILE")"
test_count="$(echo "$ab_data" | jq '.tests | length')"
assert "two tests created" "$test_count" "2"
teardown

# =========================================
# Test: pick subcommand returns correct template for alternation
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
# First pick: original (0 runs each, original goes first)
pick1="$("$AB_SCRIPT" pick bug-fix 2>&1)"
assert_json_field "first pick is original" "$pick1" ".template" "bug-fix"
assert_json_field "pick shows ab_test true" "$pick1" ".ab_test" "true"
teardown

# =========================================
# Test: pick alternates between original and variant
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
# Record a run for original
"$AB_SCRIPT" record bug-fix original 2>&1
# Next pick should be variant (1 original, 0 variant)
pick2="$("$AB_SCRIPT" pick bug-fix 2>&1)"
assert_json_field "second pick is variant" "$pick2" ".template" "bug-fix-v1"
teardown

# =========================================
# Test: pick returns base template when no active test
# =========================================
setup
pick="$("$AB_SCRIPT" pick bug-fix 2>&1)"
assert_json_field "no test returns base" "$pick" ".template" "bug-fix"
assert_json_field "no test ab_test false" "$pick" ".ab_test" "false"
teardown

# =========================================
# Test: record subcommand increments run count
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
"$AB_SCRIPT" record bug-fix original 2>&1
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "original_runs incremented" "$ab_data" ".tests[0].original_runs" "1"
assert_json_field "variant_runs unchanged" "$ab_data" ".tests[0].variant_runs" "0"
"$AB_SCRIPT" record bug-fix variant 2>&1
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "variant_runs incremented" "$ab_data" ".tests[0].variant_runs" "1"
teardown

# =========================================
# Test: evaluate subcommand - variant wins (score diff >= 0.1)
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.4 10 0.4 "bug-fix-v1" 0.6 10 0.6
# Create test with enough runs
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
out="$("$AB_SCRIPT" evaluate 2>&1)"
assert_contains "promote message" "$out" "Promoted"
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "test marked completed" "$ab_data" ".tests[0].status" "completed"
assert_json_field "test has decision" "$ab_data" ".tests[0].decision" "promoted"
teardown

# =========================================
# Test: evaluate subcommand - variant loses (score diff < 0.1)
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.5 10 0.5 "bug-fix-v1" 0.55 10 0.55
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
out="$("$AB_SCRIPT" evaluate 2>&1)"
assert_contains "discard message" "$out" "Discarded"
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "test marked completed" "$ab_data" ".tests[0].status" "completed"
assert_json_field "test has decision discarded" "$ab_data" ".tests[0].decision" "discarded"
teardown

# =========================================
# Test: evaluate skips tests without enough runs
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.4 5 0.4 "bug-fix-v1" 0.6 5 0.6
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 5, variant_runs: 5,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
out="$("$AB_SCRIPT" evaluate 2>&1)"
assert_contains "skips incomplete" "$out" "not ready"
ab_data="$(cat "$AB_TESTS_FILE")"
assert_json_field "still active" "$ab_data" ".tests[0].status" "active"
teardown

# =========================================
# Test: promote archives original template
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.3 10 0.3 "bug-fix-v1" 0.7 10 0.7
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
"$AB_SCRIPT" evaluate 2>&1
assert "original archived" "$(test -f "$TEMPLATES_DIR/.archive/bug-fix.md" && echo yes)" "yes"
assert "variant becomes new template" "$(test -f "$TEMPLATES_DIR/bug-fix.md" && echo yes)" "yes"
teardown

# =========================================
# Test: discard removes variant file
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.5 10 0.5 "bug-fix-v1" 0.5 10 0.5
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
"$AB_SCRIPT" evaluate 2>&1
assert "variant archived on discard" "$(test -f "$TEMPLATES_DIR/.archive/bug-fix-v1.md" && echo yes)" "yes"
teardown

# =========================================
# Test: evaluate logs to refinement-log.json
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.4 10 0.4 "bug-fix-v1" 0.6 10 0.6
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "active",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
"$AB_SCRIPT" evaluate 2>&1
assert "refinement log exists" "$(test -f "$REFINEMENT_LOG" && echo yes)" "yes"
log_data="$(cat "$REFINEMENT_LOG")"
assert_json_field "log has entries" "$log_data" ".entries | length | . > 0" "true"
assert_json_field "log entry has decision" "$log_data" ".entries[-1].decision" "promoted"
assert_json_field "log entry has original_score" "$log_data" ".entries[-1].original_score | . != null" "true"
assert_json_field "log entry has variant_score" "$log_data" ".entries[-1].variant_score | . != null" "true"
teardown

# =========================================
# Test: list subcommand shows active tests
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
out="$("$AB_SCRIPT" list 2>&1)"
assert_contains "list shows original" "$out" "bug-fix"
assert_contains "list shows variant" "$out" "bug-fix-v1"
assert_contains "list shows status" "$out" "active"
teardown

# =========================================
# Test: list with no tests
# =========================================
setup
out="$("$AB_SCRIPT" list 2>&1)"
assert_contains "list no tests" "$out" "No A/B tests"
teardown

# =========================================
# Test: evaluate skips already completed tests
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
create_two_scores "bug-fix" 0.4 10 0.4 "bug-fix-v1" 0.6 10 0.6
jq -n '{schema_version: "1.0.0", tests: [{
  original: "bug-fix", variant: "bug-fix-v1", status: "completed",
  target_runs: 10, original_runs: 10, variant_runs: 10,
  decision: "promoted", created_at: "2026-01-01T00:00:00Z"
}]}' > "$AB_TESTS_FILE"
out="$("$AB_SCRIPT" evaluate 2>&1)"
assert_contains "skips completed" "$out" "No active"
teardown

# =========================================
# Test: select-template integration - pick returns variant info
# =========================================
setup
create_template "bug-fix"
create_variant "bug-fix" 1
"$AB_SCRIPT" create bug-fix bug-fix-v1 2>&1
pick="$("$AB_SCRIPT" pick bug-fix 2>&1)"
assert_json_field "pick has ab_test field" "$pick" ".ab_test" "true"
assert_json_field "pick has original field" "$pick" ".original" "bug-fix"
assert_json_field "pick has variant field" "$pick" ".variant" "bug-fix-v1"
teardown

# =========================================
# Summary
# =========================================
echo ""
echo "Results: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
