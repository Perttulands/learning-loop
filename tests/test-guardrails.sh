#!/usr/bin/env bash
# test-guardrails.sh - Tests for safety guardrails (US-402)
set -euo pipefail

PASS=0
FAIL=0
assert() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARDRAILS="$PROJECT_DIR/scripts/guardrails.sh"

# Setup temp dirs
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SCORES_DIR="$WORK_DIR/scores"
TEMPLATES_DIR="$WORK_DIR/templates"
FEEDBACK_DIR="$WORK_DIR/feedback"
AB_TESTS_FILE="$SCORES_DIR/ab-tests.json"
REFINEMENT_LOG="$SCORES_DIR/refinement-log.json"
mkdir -p "$SCORES_DIR" "$TEMPLATES_DIR" "$FEEDBACK_DIR"

export SCORES_DIR TEMPLATES_DIR FEEDBACK_DIR AB_TESTS_FILE REFINEMENT_LOG

# === Script existence ===
assert "guardrails.sh exists" "[[ -f '$GUARDRAILS' ]]"
assert "guardrails.sh is executable" "[[ -x '$GUARDRAILS' ]]"

# === Usage ===
usage_out="$("$GUARDRAILS" --help 2>&1 || true)"
assert "usage shows subcommands" "echo '$usage_out' | grep -q 'check-variant-limit'"

# ==========================================
# Test 1: Max 3 active variants per template
# ==========================================
echo '{"schema_version":"1.0.0","tests":[]}' > "$AB_TESTS_FILE"
mkdir -p "$TEMPLATES_DIR/.archive"

# Create 3 active variants for bug-fix
for i in 1 2 3; do
  cat > "$TEMPLATES_DIR/bug-fix-v${i}.md" <<< "variant $i"
  jq --arg orig "bug-fix" --arg var "bug-fix-v${i}" \
    '.tests += [{"original":$orig,"variant":$var,"status":"active","target_runs":10,"original_runs":0,"variant_runs":0,"created_at":"2026-01-01T00:00:00Z"}]' \
    "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"
done

# With exactly 3, limit is ok
limit_out="$("$GUARDRAILS" check-variant-limit bug-fix 2>&1)"
assert "variant limit ok with 3 active" "echo '$limit_out' | grep -q 'ok'"

# Adding a 4th triggers enforcement
cat > "$TEMPLATES_DIR/bug-fix-v4.md" <<< "variant 4"
jq --arg orig "bug-fix" --arg var "bug-fix-v4" \
  '.tests += [{"original":$orig,"variant":$var,"status":"active","target_runs":10,"original_runs":0,"variant_runs":0,"created_at":"2026-01-02T00:00:00Z"}]' \
  "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

"$GUARDRAILS" enforce-variant-limit bug-fix
remaining2="$(jq '[.tests[] | select(.status == "active" and .original == "bug-fix")] | length' "$AB_TESTS_FILE")"
assert "enforce-variant-limit keeps max 3 after adding 4th" "[[ '$remaining2' -le 3 ]]"

# Oldest (v1) should be discarded
v1_status="$(jq -r '[.tests[] | select(.variant == "bug-fix-v1")] | .[0].status' "$AB_TESTS_FILE")"
assert "oldest variant (v1) is discarded" "[[ '$v1_status' == 'completed' ]]"

# Archived variant file
assert "discarded variant file archived" "[[ -f '$TEMPLATES_DIR/.archive/bug-fix-v1.md' ]]"

# ==========================================
# Test 2: Minimum sample size enforcement
# ==========================================

# No scoring below 5 runs - already done in score-templates.sh (confidence: low)
# No refinement below 10 runs - already done in refine-prompts.sh
# Test the check function
check_out="$("$GUARDRAILS" check-sample-size 3 scoring 2>&1)"
assert "sample-size rejects scoring with 3 runs" "echo '$check_out' | grep -q 'insufficient'"

check_out2="$("$GUARDRAILS" check-sample-size 5 scoring 2>&1)"
assert "sample-size accepts scoring with 5 runs" "echo '$check_out2' | grep -q 'sufficient'"

check_out3="$("$GUARDRAILS" check-sample-size 8 refinement 2>&1)"
assert "sample-size rejects refinement with 8 runs" "echo '$check_out3' | grep -q 'insufficient'"

check_out4="$("$GUARDRAILS" check-sample-size 10 refinement 2>&1)"
assert "sample-size accepts refinement with 10 runs" "echo '$check_out4' | grep -q 'sufficient'"

# ==========================================
# Test 3: Auto-rollback
# ==========================================

# Create a promoted template scenario: feature was promoted, now scores worse for 10 runs
echo '{"schema_version":"1.0.0","tests":[]}' > "$AB_TESTS_FILE"
mkdir -p "$SCORES_DIR"
mkdir -p "$TEMPLATES_DIR/.archive"

# Setup: feature was promoted from feature-v1, original archived
cat > "$TEMPLATES_DIR/feature.md" <<< "promoted variant content"
cat > "$TEMPLATES_DIR/.archive/feature.md" <<< "original content"

# Create refinement log with the promotion record
cat > "$REFINEMENT_LOG" <<EOF
{"schema_version":"1.0.0","entries":[
  {"type":"ab_test_result","original":"feature","variant":"feature-v1","decision":"promoted","original_score":0.6,"variant_score":0.8,"timestamp":"2026-01-01T00:00:00Z"}
]}
EOF

# Create 10 feedback records for the promoted template showing bad results
for i in $(seq 1 10); do
  cat > "$FEEDBACK_DIR/promoted-test-${i}.json" <<EOF
{"schema_version":"1.0.0","bead":"promoted-test-${i}","timestamp":"2026-01-15T00:00:00Z","template":"feature","agent":"coder","model":"gpt-4","outcome":"agent_failure","signals":{"exit_clean":false,"tests_pass":false,"lint_pass":true,"ubs_clean":true,"truthsayer_clean":true,"duration_ratio":1.0,"retried":false},"failure_patterns":[],"prompt_hash":"hash-promoted-${i}"}
EOF
done

# Create template-scores.json showing poor performance
cat > "$SCORES_DIR/template-scores.json" <<EOF
{"schema_version":"1.0.0","generated_at":"2026-01-15T00:00:00Z","templates":[
  {"template":"feature","total_runs":10,"scoreable_runs":10,"full_pass_rate":0.1,"partial_pass_rate":0.1,"retry_rate":0.0,"timeout_rate":0.0,"score":0.14,"confidence":"medium","trend":"declining","agents":[]}
]}
EOF

rollback_out="$("$GUARDRAILS" check-rollback 2>&1)"
assert "rollback detects regressed promoted template" "echo '$rollback_out' | grep -q 'feature'"

# Test that rollback reverts
"$GUARDRAILS" auto-rollback
assert "auto-rollback restores archived original" "[[ -f '$TEMPLATES_DIR/feature.md' ]]"
original_content="$(cat "$TEMPLATES_DIR/feature.md")"
assert "auto-rollback restores original content" "[[ '$original_content' == 'original content' ]]"

# ==========================================
# Test 4: --no-auto-promote flag
# ==========================================
echo '{"schema_version":"1.0.0","tests":[]}' > "$AB_TESTS_FILE"
cat > "$TEMPLATES_DIR/docs.md" <<< "original docs"
cat > "$TEMPLATES_DIR/docs-v1.md" <<< "variant docs"

# Create an A/B test that's ready for evaluation
jq '.tests += [{"original":"docs","variant":"docs-v1","status":"active","target_runs":5,"original_runs":5,"variant_runs":5,"created_at":"2026-01-01T00:00:00Z"}]' \
  "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

# Scores: variant much better
cat > "$SCORES_DIR/template-scores.json" <<EOF
{"schema_version":"1.0.0","generated_at":"2026-01-15T00:00:00Z","templates":[
  {"template":"docs","total_runs":5,"scoreable_runs":5,"full_pass_rate":0.2,"score":0.2,"confidence":"medium","trend":"stable","agents":[]},
  {"template":"docs-v1","total_runs":5,"scoreable_runs":5,"full_pass_rate":0.9,"score":0.9,"confidence":"medium","trend":"stable","agents":[]}
]}
EOF

# With --no-auto-promote, evaluate should flag but not promote
no_promote_out="$(NO_AUTO_PROMOTE=true "$GUARDRAILS" check-promote docs docs-v1 0.2 0.9 2>&1)"
assert "no-auto-promote flags variant for review" "echo '$no_promote_out' | grep -qi 'human\|review\|gated'"

# Without the flag, it should allow
allow_out="$("$GUARDRAILS" check-promote docs docs-v1 0.2 0.9 2>&1)"
assert "auto-promote allowed without flag" "echo '$allow_out' | grep -qi 'allow\|proceed'"

# ==========================================
# Test 5: Prompt hash deduplication
# ==========================================

# Create feedback records with same prompt_hash
for i in 1 2 3; do
  cat > "$FEEDBACK_DIR/dup-${i}.json" <<EOF
{"schema_version":"1.0.0","bead":"dup-${i}","timestamp":"2026-01-10T00:00:00Z","template":"script","agent":"coder","model":"gpt-4","outcome":"full_pass","signals":{"exit_clean":true,"tests_pass":true,"lint_pass":true,"ubs_clean":true,"truthsayer_clean":true,"duration_ratio":0.5,"retried":false},"failure_patterns":[],"prompt_hash":"same-hash-123"}
EOF
done
# One with different hash
cat > "$FEEDBACK_DIR/unique-1.json" <<EOF
{"schema_version":"1.0.0","bead":"unique-1","timestamp":"2026-01-10T00:00:00Z","template":"script","agent":"coder","model":"gpt-4","outcome":"full_pass","signals":{"exit_clean":true,"tests_pass":true,"lint_pass":true,"ubs_clean":true,"truthsayer_clean":true,"duration_ratio":0.5,"retried":false},"failure_patterns":[],"prompt_hash":"different-hash"}
EOF

dedup_out="$("$GUARDRAILS" check-duplicates script 2>&1)"
assert "duplicate detection finds same-hash entries" "echo '$dedup_out' | grep -q 'same-hash-123'"
assert "duplicate detection reports count" "echo '$dedup_out' | grep -q '3\|duplicat'"

# Dedup returns unique count
unique_count="$("$GUARDRAILS" count-unique script)"
assert "unique count excludes duplicates" "[[ '$unique_count' -eq 2 ]]"

# ==========================================
# Test 6: Refinement loop breaker
# ==========================================

# Create refinement log with 5 refinements for same template, no improvement
cat > "$REFINEMENT_LOG" <<EOF
{"schema_version":"1.0.0","entries":[
  {"template":"bug-fix","variant":"bug-fix-v1","trigger":"low_pass_rate","timestamp":"2026-01-01T00:00:00Z","full_pass_rate":0.3,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"bug-fix","variant":"bug-fix-v2","trigger":"low_pass_rate","timestamp":"2026-01-02T00:00:00Z","full_pass_rate":0.28,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"bug-fix","variant":"bug-fix-v3","trigger":"low_pass_rate","timestamp":"2026-01-03T00:00:00Z","full_pass_rate":0.25,"total_runs":15,"patterns_applied":["lint-failure"]},
  {"template":"bug-fix","variant":"bug-fix-v4","trigger":"low_pass_rate","timestamp":"2026-01-04T00:00:00Z","full_pass_rate":0.22,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"bug-fix","variant":"bug-fix-v5","trigger":"low_pass_rate","timestamp":"2026-01-05T00:00:00Z","full_pass_rate":0.20,"total_runs":15,"patterns_applied":["test-failure"]}
]}
EOF

loop_out="$("$GUARDRAILS" check-refinement-loop bug-fix 2>&1)"
assert "refinement loop detected after 5 attempts" "echo '$loop_out' | grep -qi 'loop\|human\|review\|breaker'"

# Template with only 2 refinements should be fine
loop_ok="$("$GUARDRAILS" check-refinement-loop feature 2>&1)"
assert "no loop for template with <5 refinements" "echo '$loop_ok' | grep -qi 'ok\|clear\|no loop'"

# Template with improvement should be ok too (create log with improving scores)
cat > "$REFINEMENT_LOG" <<EOF
{"schema_version":"1.0.0","entries":[
  {"template":"refactor","variant":"refactor-v1","trigger":"low_pass_rate","timestamp":"2026-01-01T00:00:00Z","full_pass_rate":0.3,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"refactor","variant":"refactor-v2","trigger":"low_pass_rate","timestamp":"2026-01-02T00:00:00Z","full_pass_rate":0.35,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"refactor","variant":"refactor-v3","trigger":"low_pass_rate","timestamp":"2026-01-03T00:00:00Z","full_pass_rate":0.4,"total_runs":15,"patterns_applied":["lint-failure"]},
  {"template":"refactor","variant":"refactor-v4","trigger":"low_pass_rate","timestamp":"2026-01-04T00:00:00Z","full_pass_rate":0.45,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"refactor","variant":"refactor-v5","trigger":"low_pass_rate","timestamp":"2026-01-05T00:00:00Z","full_pass_rate":0.50,"total_runs":15,"patterns_applied":["test-failure"]}
]}
EOF

loop_improving="$("$GUARDRAILS" check-refinement-loop refactor 2>&1)"
assert "no loop for template with improving scores" "echo '$loop_improving' | grep -qi 'ok\|clear\|improving\|no loop'"

# ==========================================
# Test 7: Integration - refine-prompts.sh respects loop breaker
# ==========================================

# Create scenario where refine-prompts would trigger but loop breaker stops it
cat > "$REFINEMENT_LOG" <<EOF
{"schema_version":"1.0.0","entries":[
  {"template":"script","variant":"script-v1","trigger":"low_pass_rate","timestamp":"2026-01-01T00:00:00Z","full_pass_rate":0.3,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"script","variant":"script-v2","trigger":"low_pass_rate","timestamp":"2026-01-02T00:00:00Z","full_pass_rate":0.28,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"script","variant":"script-v3","trigger":"low_pass_rate","timestamp":"2026-01-03T00:00:00Z","full_pass_rate":0.25,"total_runs":15,"patterns_applied":["lint-failure"]},
  {"template":"script","variant":"script-v4","trigger":"low_pass_rate","timestamp":"2026-01-04T00:00:00Z","full_pass_rate":0.22,"total_runs":15,"patterns_applied":["test-failure"]},
  {"template":"script","variant":"script-v5","trigger":"low_pass_rate","timestamp":"2026-01-05T00:00:00Z","full_pass_rate":0.20,"total_runs":15,"patterns_applied":["test-failure"]}
]}
EOF

cat > "$SCORES_DIR/template-scores.json" <<EOF
{"schema_version":"1.0.0","generated_at":"2026-01-15T00:00:00Z","templates":[
  {"template":"script","total_runs":15,"scoreable_runs":15,"full_pass_rate":0.2,"partial_pass_rate":0.1,"retry_rate":0.0,"timeout_rate":0.0,"score":0.24,"confidence":"medium","trend":"declining","agents":[]}
]}
EOF

cat > "$TEMPLATES_DIR/script.md" <<< "template content"

# Run refine-prompts with guardrails active
refine_out="$(REGISTRY_FILE="$WORK_DIR/empty-registry.json" "$PROJECT_DIR/scripts/refine-prompts.sh" --dry-run 2>&1)"
assert "refine-prompts skips loop-broken template" "echo '$refine_out' | grep -qi 'loop\|skip\|human\|breaker' || echo '$refine_out' | grep -q 'No templates'"

# ==========================================
# Test 8: Integration - ab-tests.sh respects --no-auto-promote
# ==========================================

echo '{"schema_version":"1.0.0","tests":[]}' > "$AB_TESTS_FILE"
cat > "$TEMPLATES_DIR/code-review.md" <<< "original code-review"
cat > "$TEMPLATES_DIR/code-review-v1.md" <<< "variant code-review"

jq '.tests += [{"original":"code-review","variant":"code-review-v1","status":"active","target_runs":5,"original_runs":5,"variant_runs":5,"created_at":"2026-01-01T00:00:00Z"}]' \
  "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

cat > "$SCORES_DIR/template-scores.json" <<EOF
{"schema_version":"1.0.0","generated_at":"2026-01-15T00:00:00Z","templates":[
  {"template":"code-review","total_runs":5,"scoreable_runs":5,"full_pass_rate":0.2,"score":0.2,"confidence":"medium","trend":"stable","agents":[]},
  {"template":"code-review-v1","total_runs":5,"scoreable_runs":5,"full_pass_rate":0.9,"score":0.9,"confidence":"medium","trend":"stable","agents":[]}
]}
EOF

# With NO_AUTO_PROMOTE, evaluate should not promote
eval_out="$(NO_AUTO_PROMOTE=true "$PROJECT_DIR/scripts/ab-tests.sh" evaluate 2>&1)"
cr_status="$(jq -r '[.tests[] | select(.variant == "code-review-v1")] | .[0].status' "$AB_TESTS_FILE")"
assert "no-auto-promote keeps test active or flags" "[[ '$cr_status' == 'active' ]] || echo '$eval_out' | grep -qi 'human\|gated\|review'"

# ==========================================
# Test 9: Integration - feedback-collector dedup tracking
# ==========================================
clean_feedback="$(mktemp -d)"
export FEEDBACK_DIR="$clean_feedback"

# Create a run record with a prompt_hash
cat > "$WORK_DIR/run-a.json" <<EOF
{"bead":"test-dedup-a","status":"done","exit_code":0,"agent":"coder","model":"gpt-4","template_name":"feature","prompt_hash":"hash-abc","attempt":1,"duration_seconds":300,"verification":{"tests":"pass","lint":"pass","ubs":"clean","truthsayer":"pass"}}
EOF

# Create another with same hash (retry)
cat > "$WORK_DIR/run-b.json" <<EOF
{"bead":"test-dedup-b","status":"done","exit_code":0,"agent":"coder","model":"gpt-4","template_name":"feature","prompt_hash":"hash-abc","attempt":2,"duration_seconds":300,"verification":{"tests":"pass","lint":"pass","ubs":"clean","truthsayer":"pass"}}
EOF

REGISTRY_FILE="$clean_feedback/pattern-registry.json" "$PROJECT_DIR/scripts/feedback-collector.sh" "$WORK_DIR/run-a.json"
REGISTRY_FILE="$clean_feedback/pattern-registry.json" "$PROJECT_DIR/scripts/feedback-collector.sh" "$WORK_DIR/run-b.json"

# Both records exist, but second should have retried=true
retried_val="$(jq '.signals.retried' "$clean_feedback/test-dedup-b.json")"
assert "retry detected via attempt field" "[[ '$retried_val' == 'true' ]]"

# prompt_hash preserved for dedup tracking
hash_a="$(jq -r '.prompt_hash' "$clean_feedback/test-dedup-a.json")"
hash_b="$(jq -r '.prompt_hash' "$clean_feedback/test-dedup-b.json")"
assert "prompt hash preserved in feedback" "[[ '$hash_a' == 'hash-abc' && '$hash_b' == 'hash-abc' ]]"

rm -rf "$clean_feedback"
export FEEDBACK_DIR="$WORK_DIR/feedback"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Guardrails Tests ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
TOTAL=$((PASS + FAIL))
echo "TOTAL: $TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
