#!/usr/bin/env bash
# backup-state.sh - Backup and restore learning-loop state
# Usage:
#   ./scripts/backup-state.sh backup
#   ./scripts/backup-state.sh list
#   ./scripts/backup-state.sh restore <archive-file>
# Env:
#   STATE_DIR (default: state/)
#   BACKUP_DIR (default: state/backups/)
#   BACKUP_RETENTION_DAYS (default: 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/state/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

usage() {
  echo "Usage: $0 <backup|list|restore <archive-file>>"
}

ensure_dirs() {
  mkdir -p "$BACKUP_DIR"
  mkdir -p "$STATE_DIR"
}

cmd_backup() {
  ensure_dirs

  if [[ ! -d "$STATE_DIR" ]]; then
    echo "Error: STATE_DIR does not exist: $STATE_DIR" >&2
    exit 1
  fi

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$BACKUP_DIR/learning-loop-state-${ts}.tar.gz"

  tar -czf "$archive" -C "$STATE_DIR" .

  # Retention policy
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'learning-loop-state-*.tar.gz' -mtime "+$BACKUP_RETENTION_DAYS" -delete

  echo "Backup created: $archive"
}

cmd_list() {
  ensure_dirs
  shopt -s nullglob
  files=("$BACKUP_DIR"/learning-loop-state-*.tar.gz)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No backups found."
    return
  fi

  for f in "${files[@]}"; do
    echo "$f"
  done
}

cmd_restore() {
  ensure_dirs

  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 restore <archive-file>" >&2
    exit 1
  fi

  archive="$1"
  if [[ ! -f "$archive" ]]; then
    echo "Error: archive not found: $archive" >&2
    exit 1
  fi

  tar -xzf "$archive" -C "$STATE_DIR"
  echo "State restored from: $archive"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  backup)
    cmd_backup
    ;;
  list)
    cmd_list
    ;;
  restore)
    shift
    cmd_restore "$@"
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
