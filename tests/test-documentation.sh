#!/usr/bin/env bash
set -euo pipefail

# Test US-404: Documentation and integration polish
# Validates that all required documentation files exist with expected content

PASS=0
FAIL=0
ERRORS=""

assert() {
  local desc="$1" condition="$2"
  if eval "$condition"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: ${desc}"
  fi
}

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- docs/flywheel.md ---
assert "docs/flywheel.md exists" "[ -f '$PROJECT_DIR/docs/flywheel.md' ]"
assert "flywheel.md mentions feedback loop" "grep -q 'feedback' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions per-run loop" "grep -qi 'per-run\|per run\|run feedback' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions hourly scoring" "grep -qi 'hourly\|score-templates' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions daily refinement" "grep -qi 'daily\|refine-prompts' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions weekly strategy" "grep -qi 'weekly\|weekly-strategy' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions feedback-collector.sh" "grep -q 'feedback-collector.sh' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions score-templates.sh" "grep -q 'score-templates.sh' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions select-template.sh" "grep -q 'select-template.sh' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions guardrails" "grep -qi 'guardrail' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md mentions notifications" "grep -qi 'notif' '$PROJECT_DIR/docs/flywheel.md'"
assert "flywheel.md describes data flow" "grep -qi 'state/feedback\|state/scores' '$PROJECT_DIR/docs/flywheel.md'"

# --- docs/templates-guide.md ---
assert "docs/templates-guide.md exists" "[ -f '$PROJECT_DIR/docs/templates-guide.md' ]"
assert "templates-guide.md mentions variant" "grep -qi 'variant' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions A/B testing" "grep -qi 'a/b\|ab.test' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions promotion" "grep -qi 'promot' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions archive" "grep -qi 'archive' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions refinement triggers" "grep -qi 'trigger\|threshold' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions scoring formula" "grep -qi 'score\|full_pass_rate' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions refine-prompts.sh" "grep -q 'refine-prompts.sh' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions ab-tests.sh" "grep -q 'ab-tests.sh' '$PROJECT_DIR/docs/templates-guide.md'"
assert "templates-guide.md mentions discard" "grep -qi 'discard' '$PROJECT_DIR/docs/templates-guide.md'"

# --- AGENTS.md ---
assert "AGENTS.md exists" "[ -f '$PROJECT_DIR/AGENTS.md' ]"
assert "AGENTS.md lists scripts" "grep -q 'scripts/' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions feedback-collector.sh" "grep -q 'feedback-collector.sh' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions score-templates.sh" "grep -q 'score-templates.sh' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions select-template.sh" "grep -q 'select-template.sh' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions refine-prompts.sh" "grep -q 'refine-prompts.sh' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions guardrails.sh" "grep -q 'guardrails.sh' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions env vars" "grep -qi 'FEEDBACK_DIR\|SCORES_DIR' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions TDD or testing" "grep -qi 'test\|TDD' '$PROJECT_DIR/AGENTS.md'"
assert "AGENTS.md mentions JSON state" "grep -qi 'json\|state/' '$PROJECT_DIR/AGENTS.md'"

# --- README.md learning loop section ---
assert "README.md mentions learning loop scripts" "grep -q 'scripts/' '$PROJECT_DIR/README.md'"
assert "README.md mentions all 4 loops" "grep -c 'feedback-collector\|score-templates\|refine-prompts\|weekly-strategy' '$PROJECT_DIR/README.md' | grep -q '[4-9]'"
assert "README.md mentions cron" "grep -qi 'cron' '$PROJECT_DIR/README.md'"
assert "README.md lists key scripts" "grep -q 'select-template\|guardrails\|notify' '$PROJECT_DIR/README.md'"
assert "README.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/README.md'"

# --- retrospective.sh in docs ---
assert "AGENTS.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/AGENTS.md'"
assert "flywheel.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/docs/flywheel.md'"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$ERRORS"
  exit 1
fi
