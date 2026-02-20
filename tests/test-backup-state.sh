#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/backup-state.sh"

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

STATE_DIR="$TMPDIR_BASE/state"
BACKUP_DIR="$TMPDIR_BASE/backups"
mkdir -p "$STATE_DIR/scores" "$STATE_DIR/feedback"

# Seed state
cat > "$STATE_DIR/scores/template-scores.json" <<'JSON'
{"templates":[{"template":"bug-fix","score":0.7}]}
JSON
cat > "$STATE_DIR/feedback/sample.json" <<'JSON'
{"bead":"athena-a1","outcome":"full_pass"}
JSON

out="$(STATE_DIR="$STATE_DIR" BACKUP_DIR="$BACKUP_DIR" BACKUP_RETENTION_DAYS=30 "$SCRIPT" backup)"
assert_eq "backup command prints created path" "true" "$(echo "$out" | grep -q 'Backup created' && echo true || echo false)"

archive_file="$(ls -1 "$BACKUP_DIR"/learning-loop-state-*.tar.gz | head -n 1)"
assert_eq "archive created" "true" "$([ -f "$archive_file" ] && echo true || echo false)"

# Remove state file then restore from archive
rm -f "$STATE_DIR/feedback/sample.json"
assert_eq "sample removed before restore" "false" "$([ -f "$STATE_DIR/feedback/sample.json" ] && echo true || echo false)"

restore_out="$(STATE_DIR="$STATE_DIR" BACKUP_DIR="$BACKUP_DIR" "$SCRIPT" restore "$archive_file")"
assert_eq "restore command prints path" "true" "$(echo "$restore_out" | grep -q 'State restored' && echo true || echo false)"
assert_eq "sample restored" "true" "$([ -f "$STATE_DIR/feedback/sample.json" ] && echo true || echo false)"

# Retention removes old backups (>30 days)
old_archive="$BACKUP_DIR/learning-loop-state-20000101T000000Z.tar.gz"
cp "$archive_file" "$old_archive"
touch -d '40 days ago' "$old_archive"

STATE_DIR="$STATE_DIR" BACKUP_DIR="$BACKUP_DIR" BACKUP_RETENTION_DAYS=30 "$SCRIPT" backup >/dev/null
assert_eq "old archive removed by retention" "false" "$([ -f "$old_archive" ] && echo true || echo false)"


echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
