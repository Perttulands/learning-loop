#!/usr/bin/env bash
# guardrails.sh - Safety guardrails for the learning loop
# Usage: ./scripts/guardrails.sh <subcommand> [args]
# Env: SCORES_DIR, TEMPLATES_DIR, FEEDBACK_DIR, AB_TESTS_FILE, REFINEMENT_LOG
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$PROJECT_DIR/templates}"
FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
AB_TESTS_FILE="${AB_TESTS_FILE:-$SCORES_DIR/ab-tests.json}"
REFINEMENT_LOG="${REFINEMENT_LOG:-$SCORES_DIR/refinement-log.json}"

MAX_ACTIVE_VARIANTS=3
MIN_SCORING_RUNS=5
MIN_REFINEMENT_RUNS=10
ROLLBACK_RUN_THRESHOLD=10
REFINEMENT_LOOP_LIMIT=5

usage() {
  echo "Usage: $0 <subcommand> [args]"
  echo "Subcommands:"
  echo "  check-variant-limit <template>          Check if variant limit exceeded"
  echo "  enforce-variant-limit <template>         Discard oldest variants over limit"
  echo "  check-sample-size <n> <scoring|refinement>  Check minimum sample size"
  echo "  check-rollback                           Check for promoted templates needing rollback"
  echo "  auto-rollback                            Rollback regressed promoted templates"
  echo "  check-promote <orig> <var> <os> <vs>     Check if promotion is allowed"
  echo "  check-duplicates <template>              Find duplicate prompt_hash entries"
  echo "  count-unique <template>                  Count unique prompt_hash feedback records"
  echo "  check-refinement-loop <template>         Check for refinement loop (5+ without improvement)"
  echo "  --help                                   Show this message"
}

# Check if variant limit is exceeded for a template
cmd_check_variant_limit() {
  local template="$1"
  if [[ ! -f "$AB_TESTS_FILE" ]]; then
    echo "No A/B tests file. No variants active."
    return
  fi
  local count
  count="$(jq --arg t "$template" '[.tests[] | select(.status == "active" and .original == $t)] | length' "$AB_TESTS_FILE")"
  if [[ "$count" -gt "$MAX_ACTIVE_VARIANTS" ]]; then
    echo "Variant limit exceeded for $template: $count active (max $MAX_ACTIVE_VARIANTS). Oldest will be discarded."
  else
    echo "Variant limit ok for $template: $count active (max $MAX_ACTIVE_VARIANTS)."
  fi
}

# Enforce variant limit: discard oldest active variants beyond MAX_ACTIVE_VARIANTS
cmd_enforce_variant_limit() {
  local template="$1"
  if [[ ! -f "$AB_TESTS_FILE" ]]; then
    return
  fi

  local count
  count="$(jq --arg t "$template" '[.tests[] | select(.status == "active" and .original == $t)] | length' "$AB_TESTS_FILE")"

  while [[ "$count" -gt "$MAX_ACTIVE_VARIANTS" ]]; do
    # Find oldest active variant (by created_at)
    local oldest_variant
    oldest_variant="$(jq -r --arg t "$template" \
      '[.tests[] | select(.status == "active" and .original == $t)] | sort_by(.created_at) | .[0].variant' \
      "$AB_TESTS_FILE")"

    # Mark as completed/discarded
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg var "$oldest_variant" --arg ts "$ts" \
      '(.tests[] | select(.status == "active" and .variant == $var)) |=
        (.status = "completed" | .decision = "discarded_limit" | .completed_at = $ts)' \
      "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
    mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

    # Archive variant file
    mkdir -p "$TEMPLATES_DIR/.archive"
    if [[ -f "$TEMPLATES_DIR/${oldest_variant}.md" ]]; then
      mv "$TEMPLATES_DIR/${oldest_variant}.md" "$TEMPLATES_DIR/.archive/${oldest_variant}.md"
    fi

    echo "Discarded oldest variant: $oldest_variant (limit enforcement)"
    count=$((count - 1))
  done
}

# Check minimum sample size
cmd_check_sample_size() {
  local n="$1" operation="$2"
  local min_required
  if [[ "$operation" == "scoring" ]]; then
    min_required="$MIN_SCORING_RUNS"
  else
    min_required="$MIN_REFINEMENT_RUNS"
  fi

  if [[ "$n" -lt "$min_required" ]]; then
    echo "insufficient: $n runs < minimum $min_required for $operation"
  else
    echo "sufficient: $n runs >= minimum $min_required for $operation"
  fi
}

# Check for promoted templates that are performing worse and need rollback
cmd_check_rollback() {
  if [[ ! -f "$REFINEMENT_LOG" ]] || [[ ! -f "$SCORES_DIR/template-scores.json" ]]; then
    echo "No data for rollback check."
    return
  fi

  # Find promoted templates from refinement log
  local promoted
  promoted="$(jq -r '[.entries[] | select(.type == "ab_test_result" and .decision == "promoted")] | .[] | .original' "$REFINEMENT_LOG" 2>/dev/null || true)"

  if [[ -z "$promoted" ]]; then
    echo "No promoted templates to check."
    return
  fi

  for template in $promoted; do
    # Get original score at promotion time
    local orig_score
    orig_score="$(jq -r --arg t "$template" \
      '[.entries[] | select(.type == "ab_test_result" and .decision == "promoted" and .original == $t)] | last | .original_score' \
      "$REFINEMENT_LOG")"

    # Get current score
    local current_score current_runs
    current_score="$(jq -r --arg t "$template" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].score else null end' \
      "$SCORES_DIR/template-scores.json")"
    current_runs="$(jq -r --arg t "$template" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].total_runs else 0 end' \
      "$SCORES_DIR/template-scores.json")"

    if [[ "$current_score" == "null" ]] || [[ "$current_runs" -lt "$ROLLBACK_RUN_THRESHOLD" ]]; then
      continue
    fi

    # Check if current score is worse than the original score at promotion
    local is_worse
    is_worse="$(echo "$orig_score > $current_score" | bc -l)"
    if [[ "$is_worse" == "1" ]]; then
      echo "Rollback needed: $template (current: $current_score, was: $orig_score at promotion, $current_runs runs)"
    fi
  done
}

# Auto-rollback: revert regressed promoted templates
cmd_auto_rollback() {
  if [[ ! -f "$REFINEMENT_LOG" ]] || [[ ! -f "$SCORES_DIR/template-scores.json" ]]; then
    return
  fi

  local promoted
  promoted="$(jq -r '[.entries[] | select(.type == "ab_test_result" and .decision == "promoted")] | .[] | .original' "$REFINEMENT_LOG" 2>/dev/null || true)"

  for template in $promoted; do
    local orig_score current_score current_runs
    orig_score="$(jq -r --arg t "$template" \
      '[.entries[] | select(.type == "ab_test_result" and .decision == "promoted" and .original == $t)] | last | .original_score' \
      "$REFINEMENT_LOG")"
    current_score="$(jq -r --arg t "$template" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].score else null end' \
      "$SCORES_DIR/template-scores.json")"
    current_runs="$(jq -r --arg t "$template" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].total_runs else 0 end' \
      "$SCORES_DIR/template-scores.json")"

    if [[ "$current_score" == "null" ]] || [[ "$current_runs" -lt "$ROLLBACK_RUN_THRESHOLD" ]]; then
      continue
    fi

    local is_worse
    is_worse="$(echo "$orig_score > $current_score" | bc -l)"
    if [[ "$is_worse" == "1" ]]; then
      # Find the archived original (pre-variant backup)
      local variant_name
      variant_name="$(jq -r --arg t "$template" \
        '[.entries[] | select(.type == "ab_test_result" and .decision == "promoted" and .original == $t)] | last | .variant' \
        "$REFINEMENT_LOG")"

      local archive_name="${template}-pre-${variant_name}"
      if [[ -f "$TEMPLATES_DIR/.archive/${archive_name}.md" ]]; then
        cp "$TEMPLATES_DIR/.archive/${archive_name}.md" "$TEMPLATES_DIR/${template}.md"
        echo "Rolled back: $template (restored from ${archive_name})"

        # Notify
        "$SCRIPT_DIR/notify.sh" score-regression \
          --template "$template" --old-score "$orig_score" --new-score "$current_score" 2>/dev/null || true
      elif [[ -f "$TEMPLATES_DIR/.archive/${template}.md" ]]; then
        # Fallback: try the plain archived original
        cp "$TEMPLATES_DIR/.archive/${template}.md" "$TEMPLATES_DIR/${template}.md"
        echo "Rolled back: $template (restored from archive)"

        "$SCRIPT_DIR/notify.sh" score-regression \
          --template "$template" --old-score "$orig_score" --new-score "$current_score" 2>/dev/null || true
      else
        echo "Warning: Cannot rollback $template — no archived original found" >&2
      fi
    fi
  done
}

# Check if promotion is allowed (respects NO_AUTO_PROMOTE)
cmd_check_promote() {
  local orig="$1" var="$2" orig_score="$3" var_score="$4"

  if [[ "${NO_AUTO_PROMOTE:-false}" == "true" ]]; then
    echo "Promotion gated: $var beats $orig but NO_AUTO_PROMOTE is set. Requires human review."
    return
  fi

  echo "Promotion allowed: proceed with promoting $var over $orig."
}

# Find duplicate prompt_hash entries for a template
cmd_check_duplicates() {
  local template="$1"

  shopt -s nullglob
  local files=("$FEEDBACK_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No feedback records found."
    return
  fi

  jq -s --arg t "$template" '
    [.[] | select(.bead != null and .template == $t and .prompt_hash != null and .prompt_hash != "")] |
    group_by(.prompt_hash) |
    [.[] | select(length > 1) | {hash: .[0].prompt_hash, count: length, beads: [.[].bead]}] |
    if length > 0 then
      .[] | "Duplicate prompt_hash: \(.hash) (\(.count) records: \(.beads | join(", ")))"
    else "No duplicates found." end
  ' "${files[@]}"
}

# Count unique feedback records for a template (by prompt_hash)
cmd_count_unique() {
  local template="$1"

  shopt -s nullglob
  local files=("$FEEDBACK_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "0"
    return
  fi

  jq -s --arg t "$template" '
    [.[] | select(.bead != null and .template == $t)] |
    [.[] | .prompt_hash // .bead] | unique | length
  ' "${files[@]}"
}

# Check for refinement loop: 5+ refinements without improvement
cmd_check_refinement_loop() {
  local template="$1"

  if [[ ! -f "$REFINEMENT_LOG" ]]; then
    echo "No refinement loop: no refinement log found. Clear."
    return
  fi

  local refinements
  refinements="$(jq --arg t "$template" \
    '[.entries[] | select(.template == $t and .trigger != null)] | length' \
    "$REFINEMENT_LOG")"

  if [[ "$refinements" -lt "$REFINEMENT_LOOP_LIMIT" ]]; then
    echo "No refinement loop for $template: $refinements refinements (limit: $REFINEMENT_LOOP_LIMIT). Clear."
    return
  fi

  # Check if scores improved across refinements
  local first_rate last_rate
  first_rate="$(jq --arg t "$template" \
    '[.entries[] | select(.template == $t and .trigger != null)] | first | .full_pass_rate' \
    "$REFINEMENT_LOG")"
  last_rate="$(jq --arg t "$template" \
    '[.entries[] | select(.template == $t and .trigger != null)] | last | .full_pass_rate' \
    "$REFINEMENT_LOG")"

  local improved
  improved="$(echo "$last_rate > $first_rate" | bc -l)"
  if [[ "$improved" == "1" ]]; then
    echo "No refinement loop for $template: scores improving ($first_rate → $last_rate). Clear."
  else
    echo "Refinement loop breaker: $template has $refinements refinements without improvement ($first_rate → $last_rate). Flag for human review."
  fi
}

# Main dispatch
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  check-variant-limit)
    shift; cmd_check_variant_limit "$1" ;;
  enforce-variant-limit)
    shift; cmd_enforce_variant_limit "$1" ;;
  check-sample-size)
    shift; cmd_check_sample_size "$1" "$2" ;;
  check-rollback)
    cmd_check_rollback ;;
  auto-rollback)
    cmd_auto_rollback ;;
  check-promote)
    shift; cmd_check_promote "$1" "$2" "$3" "$4" ;;
  check-duplicates)
    shift; cmd_check_duplicates "$1" ;;
  count-unique)
    shift; cmd_count_unique "$1" ;;
  check-refinement-loop)
    shift; cmd_check_refinement_loop "$1" ;;
  --help|-h)
    usage ;;
  *)
    echo "Unknown subcommand: $1" >&2
    usage
    exit 1 ;;
esac
