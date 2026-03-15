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

# --- archived shell-era docs ---
assert "docs/archive/flywheel.md exists" "[ -f '$PROJECT_DIR/docs/archive/flywheel.md' ]"
assert "docs/archive/judge-design.md exists" "[ -f '$PROJECT_DIR/docs/archive/judge-design.md' ]"
assert "docs/archive/templates-guide.md exists" "[ -f '$PROJECT_DIR/docs/archive/templates-guide.md' ]"
assert "archived flywheel.md mentions feedback loop" "grep -q 'feedback' '$PROJECT_DIR/docs/archive/flywheel.md'"
assert "archived flywheel.md mentions per-run loop" "grep -qi 'per-run\|per run\|run feedback' '$PROJECT_DIR/docs/archive/flywheel.md'"
assert "archived templates-guide.md mentions variant" "grep -qi 'variant' '$PROJECT_DIR/docs/archive/templates-guide.md'"
assert "archived templates-guide.md mentions A/B testing" "grep -qi 'a/b\|ab.test' '$PROJECT_DIR/docs/archive/templates-guide.md'"
assert "archived judge-design.md mentions Opus Judge" "grep -qi 'Opus Judge' '$PROJECT_DIR/docs/archive/judge-design.md'"

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
assert "README.md marks shell docs archived" "grep -q 'docs/archive/' '$PROJECT_DIR/README.md'"
assert "README.md marks scripts layer legacy" "grep -qi 'legacy / compatibility' '$PROJECT_DIR/README.md'"
assert "README.md lists key scripts" "grep -q 'select-template\|guardrails\|notify' '$PROJECT_DIR/README.md'"
assert "README.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/README.md'"

# --- retrospective.sh in docs ---
assert "AGENTS.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/AGENTS.md'"
assert "archived flywheel.md mentions retrospective.sh" "grep -q 'retrospective.sh' '$PROJECT_DIR/docs/archive/flywheel.md'"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$ERRORS"
  exit 1
fi
