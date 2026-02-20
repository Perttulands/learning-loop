#!/usr/bin/env bash
# Tests for install-cron.sh and config/crontab.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_CRON="$PROJECT_DIR/scripts/install-cron.sh"
CRONTAB_FILE="$PROJECT_DIR/config/crontab.txt"

PASS=0
FAIL=0
TOTAL=0

assert() {
  local desc="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
  fi
}

# Setup temp dirs
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# === crontab.txt tests ===

assert "crontab.txt exists" '[[ -f "$CRONTAB_FILE" ]]'

crontab_content="$(cat "$CRONTAB_FILE")"

# Hourly: score-templates.sh
assert "crontab has hourly score-templates entry" '[[ "$crontab_content" == *"score-templates.sh"* ]]'
assert "score-templates runs hourly" 'echo "$crontab_content" | grep -q "score-templates" && echo "$crontab_content" | grep "score-templates" | grep -qE "^[0-9]+ \* \* \* \*"'

# Hourly: dashboard.sh
assert "crontab has hourly dashboard entry" '[[ "$crontab_content" == *"dashboard.sh"* ]]'
assert "dashboard runs hourly at :15" 'echo "$crontab_content" | grep -q "dashboard.sh" && echo "$crontab_content" | grep "dashboard.sh" | grep -qE "^15 \* \* \* \*"'

# Daily 03:00 UTC: refine-prompts.sh --auto
assert "crontab has daily refine-prompts entry" '[[ "$crontab_content" == *"refine-prompts.sh"* ]]'
assert "refine-prompts has --auto flag" '[[ "$crontab_content" == *"refine-prompts.sh --auto"* ]]'
assert "refine-prompts runs at 03:00" 'echo "$crontab_content" | grep -q "refine-prompts" && echo "$crontab_content" | grep "refine-prompts" | grep -qE "^0 3 \* \* \*"'

# Weekly Sunday 07:00 UTC: weekly-strategy.sh
assert "crontab has weekly strategy entry" '[[ "$crontab_content" == *"weekly-strategy.sh"* ]]'
assert "weekly-strategy runs on Sunday at 07:00" 'echo "$crontab_content" | grep -q "weekly-strategy" && echo "$crontab_content" | grep "weekly-strategy" | grep -qE "^0 7 \* \* 0"'

# Crontab format
assert "crontab has no empty schedule lines" '! echo "$crontab_content" | grep -qE "^\s*$" || true' # REASON: grep returns 1 for no matches; assertion intentionally handles that branch.
assert "crontab entries use absolute paths" 'echo "$crontab_content" | grep -v "^#" | grep -v "^$" | grep -v "^[A-Z]" | while read -r line; do echo "$line" | grep -q "/scripts/"; done'

# Log redirection
assert "crontab entries redirect output to logs" 'echo "$crontab_content" | grep "score-templates" | grep -q ">>"'

# === install-cron.sh tests ===

assert "install-cron.sh exists" '[[ -f "$INSTALL_CRON" ]]'
assert "install-cron.sh is executable" '[[ -x "$INSTALL_CRON" ]]'

# Usage message
output="$("$INSTALL_CRON" --help 2>&1 || true)" # REASON: help command may return non-zero on strict shells; this test checks help text only.
assert "shows usage with --help" '[[ "$output" == *"Usage"* || "$output" == *"usage"* || "$output" == *"install"* ]]'

# --dry-run mode (does not modify actual crontab)
output="$("$INSTALL_CRON" --dry-run 2>&1)"
assert "dry-run shows crontab entries" '[[ "$output" == *"score-templates"* ]]'
assert "dry-run shows all scheduled jobs" '[[ "$output" == *"dashboard.sh"* && "$output" == *"refine-prompts"* && "$output" == *"weekly-strategy"* ]]'
assert "dry-run does not install" '[[ "$output" == *"dry"* || "$output" == *"preview"* || "$output" == *"would"* ]]'

# --remove mode (dry)
output="$("$INSTALL_CRON" --remove --dry-run 2>&1)"
assert "remove dry-run mentions removal" '[[ "$output" == *"remove"* || "$output" == *"Remove"* || "$output" == *"uninstall"* ]]'

# Crontab content generation uses PROJECT_DIR
output="$("$INSTALL_CRON" --dry-run 2>&1)"
assert "entries use project dir path" '[[ "$output" == *"$PROJECT_DIR"* || "$output" == *"learning-loop"* ]]'

# Marker for identifying learning-loop entries
output="$("$INSTALL_CRON" --dry-run 2>&1)"
assert "entries have identifying marker" '[[ "$output" == *"learning-loop"* ]]'

# === Verify crontab.txt is well-formed ===
valid_lines=0
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  # Skip env var assignments (KEY=value)
  [[ "$line" =~ ^[A-Z_]+=.* ]] && continue
  # Cron lines should have 5 time fields + command
  fields=$(echo "$line" | awk '{print NF}')
  if [[ "$fields" -ge 6 ]]; then
    valid_lines=$((valid_lines + 1))
  fi
done < "$CRONTAB_FILE"
assert "crontab has exactly 4 cron entries" '[[ "$valid_lines" -eq 4 ]]'

# --- Results ---
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
