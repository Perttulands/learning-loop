#!/usr/bin/env bash
# backfill.sh - Process all historical run records through feedback-collector.sh
# Usage: ./scripts/backfill.sh <runs-dir>
# Env: FEEDBACK_DIR, SCORES_DIR (passed through to sub-scripts)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <runs-dir>" >&2
  echo "  Processes all run records through feedback-collector.sh" >&2
  echo "  Then generates template-scores.json via score-templates.sh" >&2
  exit 1
fi

RUNS_DIR="$1"

if [[ ! -d "$RUNS_DIR" ]]; then
  echo "Error: runs directory not found: $RUNS_DIR" >&2
  exit 1
fi

export FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
export SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
export REGISTRY_FILE="${REGISTRY_FILE:-$FEEDBACK_DIR/pattern-registry.json}"
mkdir -p "$FEEDBACK_DIR" "$SCORES_DIR"

shopt -s nullglob
run_files=("$RUNS_DIR"/*.json)
shopt -u nullglob

total=${#run_files[@]}
processed=0
skipped=0
errors=0

for run_file in "${run_files[@]}"; do
  bead="$(basename "$run_file" .json)"
  if "$SCRIPT_DIR/feedback-collector.sh" "$run_file" 2>>"$FEEDBACK_DIR/backfill-errors.log"; then
    if [[ -f "$FEEDBACK_DIR/$bead.json" ]]; then
      processed=$((processed + 1))
    else
      skipped=$((skipped + 1))
    fi
  else
    errors=$((errors + 1))
  fi
done

# Generate template scores from backfilled feedback
"$SCRIPT_DIR/score-templates.sh"

echo "Backfill complete: $processed processed, $skipped skipped, $errors errors (of $total total)"
