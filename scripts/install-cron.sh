#!/usr/bin/env bash
# install-cron.sh - Install/remove learning loop cron jobs
# Usage: ./scripts/install-cron.sh [--dry-run] [--remove] [--help]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CRONTAB_TEMPLATE="$PROJECT_DIR/config/crontab.txt"
MARKER="# learning-loop"

DRY_RUN=false
REMOVE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --remove)  REMOVE=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--remove] [--help]"
      echo "  Install learning-loop cron jobs from config/crontab.txt"
      echo "  --dry-run  Preview entries without installing"
      echo "  --remove   Remove learning-loop entries from crontab"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# Generate entries with resolved paths
generate_entries() {
  while IFS= read -r line; do
    # Skip comment-only and blank lines from template
    if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
      continue
    fi
    # Replace placeholder with actual project dir, add marker
    echo "${line//__PROJECT_DIR__/$PROJECT_DIR} $MARKER"
  done < "$CRONTAB_TEMPLATE"
}

if $REMOVE; then
  if $DRY_RUN; then
    echo "Would remove learning-loop entries from crontab (dry-run)"
    echo "Entries matching marker: $MARKER"
    exit 0
  fi
  # Remove lines with our marker from current crontab
  existing="$(crontab -l 2>/dev/null || true)"
  filtered="$(echo "$existing" | grep -v "$MARKER" || true)"
  echo "$filtered" | crontab -
  echo "Removed learning-loop cron entries"
  exit 0
fi

entries="$(generate_entries)"

if $DRY_RUN; then
  echo "Learning-loop cron entries (dry-run preview, would install):"
  echo ""
  echo "$entries"
  exit 0
fi

# Merge: keep existing non-learning-loop entries, add ours
mkdir -p "$PROJECT_DIR/state/logs"
existing="$(crontab -l 2>/dev/null || true)"
filtered="$(echo "$existing" | grep -v "$MARKER" || true)"

{
  echo "$filtered"
  echo ""
  echo "$entries"
} | crontab -

echo "Installed learning-loop cron jobs (3 entries)"
