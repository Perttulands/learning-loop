#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELECT_SCRIPT="$PROJECT_DIR/scripts/select-template.sh"

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

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
SCORES_DIR="$TMPDIR_BASE/scores"
mkdir -p "$SCORES_DIR"

cases_file="$TMPDIR_BASE/cases.txt"
cat > "$cases_file" <<'CASES'
bug-fix|Fix failing login test on OAuth callback
bug-fix|Debug intermittent crash in payment worker
bug-fix|Resolve regression in cache invalidation logic
bug-fix|Investigate why API returns 500 for empty payload
bug-fix|Repair null pointer bug in parser
bug-fix|Hotfix broken deploy script path reference
bug-fix|Fix flaky timeout handling in queue consumer
bug-fix|Resolve production incident caused by bad retry loop
bug-fix|Debug memory leak in websocket session handler
bug-fix|Fix typo causing bad SQL column lookup
feature|Add endpoint for exporting account activity
feature|Implement support for bulk user invites
feature|Create onboarding workflow for new teams
feature|Build background job to sync partner catalog
feature|Introduce feature flag for staged rollout
feature|Add audit trail capability for admin actions
feature|Implement API to upload profile images
feature|Create integration with billing webhooks
feature|Allow users to archive completed tasks
feature|Enable MFA enrollment flow in settings
refactor|Refactor auth middleware into smaller modules
refactor|Cleanup duplicated validation logic
refactor|Simplify repository layer for maintainability
refactor|Reorganize service package structure
refactor|Extract shared retry helper from three services
refactor|Rename ambiguous variables in scheduler core
refactor|Reduce tech debt in notification pipeline
refactor|Refactor giant function into composable units
refactor|Modularize config loading path
refactor|Improve readability of permission checks
docs|Update README with local development setup
docs|Write API documentation for token refresh route
docs|Document release process in changelog section
docs|Add usage guide for CLI options
docs|Write tutorial for running smoke tests
docs|Update docs for environment variables
docs|Add inline code comments for complex migration
docs|Document how to rotate signing keys
docs|Improve docs around caching strategy
docs|Write how-to guide for backup restore
script|Write a script to prune stale branches
script|Create bash automation for dependency updates
script|Automate nightly cleanup cron job
script|Build CLI tool to generate seed data
script|Create script runner for test fixtures
script|Add scheduler task runner wrapper script
script|Automate changelog version bump
script|Write shell script to sync artifacts
code-review|Review PR for security regressions
code-review|Audit auth flow changes for risk
code-review|Analyze codebase for data race findings
code-review|Perform code review on caching patch
code-review|Assess migration patch and list severity findings
code-review|Audit error handling and report issues
custom|Plan roadmap for next quarter initiatives
custom|Brainstorm naming ideas for new product line
custom|Estimate effort for unknown integration area
custom|Prepare stakeholder update summary for leadership
CASES

total=0
correct=0

while IFS='|' read -r expected task; do
  total=$((total + 1))
  result="$(SCORES_DIR="$SCORES_DIR" "$SELECT_SCRIPT" "$task")"
  predicted="$(echo "$result" | jq -r '.task_type')"
  if [[ "$predicted" == "$expected" ]]; then
    correct=$((correct + 1))
  fi
done < "$cases_file"

accuracy="$(echo "scale=4; $correct / $total" | bc -l)"
meets_threshold="$(echo "$accuracy >= 0.90" | bc -l | cut -d'.' -f1)"

assert_eq "dataset has at least 50 labeled examples" "1" "$(echo "$total >= 50" | bc -l | cut -d'.' -f1)"
assert_eq "classification accuracy >= 90%" "1" "$meets_threshold"

echo ""
echo "Classification accuracy: $correct/$total = $accuracy"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
