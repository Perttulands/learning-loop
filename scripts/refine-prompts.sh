#!/usr/bin/env bash
# refine-prompts.sh - Automatically refine templates based on failure patterns
# Usage: ./scripts/refine-prompts.sh [--auto|--dry-run|--help]
# Env: SCORES_DIR, TEMPLATES_DIR, REGISTRY_FILE, REFINEMENT_LOG
# Triggers: full_pass_rate < 0.50 (≥10 runs), pattern count ≥ 5, declining trend
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$PROJECT_DIR/templates}"
REGISTRY_FILE="${REGISTRY_FILE:-$PROJECT_DIR/state/feedback/pattern-registry.json}"
REFINEMENT_LOG="${REFINEMENT_LOG:-$SCORES_DIR/refinement-log.json}"

MODE="preview"  # default: show what would be done

for arg in "$@"; do
  case "$arg" in
    --auto) MODE="auto" ;;
    --dry-run) MODE="dry-run" ;;
    --help|-h)
      echo "Usage: $0 [--auto|--dry-run|--help]"
      echo "  (no flag)  Preview mode: show what would be refined"
      echo "  --auto     Generate variant files and log refinements"
      echo "  --dry-run  Show triggers but create no files"
      echo "  --help     Show this message"
      exit 0
      ;;
  esac
done

SCORES_FILE="$SCORES_DIR/template-scores.json"
if [[ ! -f "$SCORES_FILE" ]]; then
  echo "No template-scores.json found at $SCORES_FILE" >&2
  exit 0
fi

# Load pattern registry (empty object if missing)
if [[ -f "$REGISTRY_FILE" ]]; then
  REGISTRY="$(cat "$REGISTRY_FILE")"
else
  REGISTRY="{}"
fi

# Refinement strategy: maps pattern name to instruction text appended to template
pattern_instruction() {
  local pattern="$1"
  case "$pattern" in
    test-failure-after-completion)
      echo "IMPORTANT: Run ALL tests before committing. If any test fails, fix it before proceeding. Verify test output shows 0 failures."
      ;;
    lint-failure-after-completion)
      echo "IMPORTANT: Run the linter after making changes. Fix all lint warnings and errors before committing."
      ;;
    scope-creep)
      echo "IMPORTANT: Stay focused on the specific task described. Do NOT refactor unrelated code or add features beyond the scope of this task."
      ;;
    incomplete-work)
      echo "IMPORTANT: Verify every requirement is complete before finishing. Check your work against the task description and ensure nothing is left unimplemented."
      ;;
    repeated-failure)
      echo "IMPORTANT: If your first approach fails, stop and analyze the root cause before retrying. Do not repeat the same failing approach."
      ;;
    verification-gap)
      echo "IMPORTANT: Run the full verification suite (tests, lint, type checks) before declaring the task complete."
      ;;
    *)
      echo "IMPORTANT: Review all checks before declaring the task complete."
      ;;
  esac
}

# Find next variant number for a template
next_variant_number() {
  local template_name="$1"
  local n=1
  while [[ -f "$TEMPLATES_DIR/${template_name}-v${n}.md" ]]; do
    n=$((n + 1))
  done
  echo "$n"
}

# Identify templates needing refinement
candidates="$(jq -r '
  [.templates[] |
    select(.total_runs >= 10) |
    select(
      .full_pass_rate < 0.50 or
      .trend == "declining"
    ) |
    .template
  ] | .[]
' "$SCORES_FILE" 2>/dev/null || true)"

# Also check pattern count >= 5 for templates with sufficient runs
if [[ -f "$REGISTRY_FILE" ]]; then
  pattern_templates="$(jq -r --argjson registry "$REGISTRY" '
    [.templates[] |
      select(.total_runs >= 10) |
      .template
    ] | .[]
  ' "$SCORES_FILE" 2>/dev/null || true)"

  # A template qualifies by pattern count if any pattern in the registry has count >= 5
  # and that template has >= 10 runs
  for tpl in $pattern_templates; do
    total_pattern_count="$(echo "$REGISTRY" | jq '[.[].count] | add // 0')"
    if [[ "$total_pattern_count" -ge 5 ]]; then
      # Add to candidates if not already there
      if ! echo "$candidates" | grep -qxF "$tpl"; then
        candidates="$(printf '%s\n%s' "$candidates" "$tpl")"
      fi
    fi
  done
fi

# Remove empty lines
candidates="$(echo "$candidates" | sed '/^$/d' | sort -u)"

if [[ -z "$candidates" ]]; then
  echo "No templates need refinement."
  exit 0
fi

refined_count=0

GUARDRAILS_SCRIPT="$SCRIPT_DIR/guardrails.sh"

for template_name in $candidates; do
  template_file="$TEMPLATES_DIR/${template_name}.md"

  if [[ ! -f "$template_file" ]]; then
    echo "Warning: Template file not found for '$template_name': $template_file" >&2
    continue
  fi

  # Refinement loop breaker: skip templates with 5+ refinements without improvement
  if [[ -x "$GUARDRAILS_SCRIPT" ]]; then
    loop_check="$("$GUARDRAILS_SCRIPT" check-refinement-loop "$template_name" 2>&1)"
    if echo "$loop_check" | grep -qi "loop breaker"; then
      echo "Skipping '$template_name': refinement loop breaker triggered. Needs human review."
      continue
    fi
  fi

  # Get score data for this template
  score_data="$(jq --arg t "$template_name" '.templates[] | select(.template == $t)' "$SCORES_FILE")"
  full_pass_rate="$(echo "$score_data" | jq -r '.full_pass_rate')"
  total_runs="$(echo "$score_data" | jq -r '.total_runs')"
  trend="$(echo "$score_data" | jq -r '.trend')"

  # Determine trigger reason
  trigger="unknown"
  if jq -e --arg t "$template_name" '.templates[] | select(.template == $t and .full_pass_rate < 0.50)' "$SCORES_FILE" > /dev/null 2>&1; then
    trigger="low_pass_rate"
  elif [[ "$trend" == "declining" ]]; then
    trigger="declining_trend"
  else
    trigger="high_pattern_count"
  fi

  # Find top patterns from registry (count >= 5)
  top_patterns="$(echo "$REGISTRY" | jq -r '[to_entries[] | select(.value.count >= 5) | .key] | .[]' 2>/dev/null || true)"

  # Build refinement instructions from patterns
  instructions=""
  patterns_applied=()
  if [[ -n "$top_patterns" ]]; then
    for pattern in $top_patterns; do
      instr="$(pattern_instruction "$pattern")"
      instructions="$instructions"$'\n'"$instr"
      patterns_applied+=("$pattern")
    done
  else
    # Fallback: generic refinement
    instructions=$'\n'"IMPORTANT: Review all checks and verify all requirements before declaring the task complete."
    patterns_applied+=("generic")
  fi

  variant_num="$(next_variant_number "$template_name")"
  variant_name="${template_name}-v${variant_num}"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "[dry-run] Would refine '$template_name' → '$variant_name' (trigger: $trigger, pass_rate: $full_pass_rate, patterns: ${patterns_applied[*]})"
    refined_count=$((refined_count + 1))
    continue
  fi

  if [[ "$MODE" == "preview" ]]; then
    echo "Would refine '$template_name' → '$variant_name' (trigger: $trigger, pass_rate: $full_pass_rate)"
    refined_count=$((refined_count + 1))
    continue
  fi

  # --auto: generate variant file
  original_content="$(cat "$template_file")"
  variant_content="${original_content}

## Refinement Notes (auto-generated)
${instructions}
"
  echo "$variant_content" > "$TEMPLATES_DIR/${variant_name}.md"

  # Log the refinement
  mkdir -p "$(dirname "$REFINEMENT_LOG")"
  patterns_json="$(printf '%s\n' "${patterns_applied[@]}" | jq -R . | jq -s .)"
  entry="$(jq -n \
    --arg template "$template_name" \
    --arg variant "$variant_name" \
    --arg trigger "$trigger" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson full_pass_rate "$full_pass_rate" \
    --argjson total_runs "$total_runs" \
    --argjson patterns "$patterns_json" \
    '{
      template: $template,
      variant: $variant,
      trigger: $trigger,
      timestamp: $ts,
      full_pass_rate: $full_pass_rate,
      total_runs: $total_runs,
      patterns_applied: $patterns
    }')"

  if [[ -f "$REFINEMENT_LOG" ]]; then
    # Append to existing log
    jq --argjson entry "$entry" '.entries += [$entry]' "$REFINEMENT_LOG" > "$REFINEMENT_LOG.tmp"
    mv "$REFINEMENT_LOG.tmp" "$REFINEMENT_LOG"
  else
    echo "$entry" | jq '{schema_version: "1.0.0", entries: [.]}' > "$REFINEMENT_LOG"
  fi

  echo "Refined '$template_name' → '$variant_name' (trigger: $trigger)"

  # Notify: variant created
  "$SCRIPT_DIR/notify.sh" variant-created \
    --template "$template_name" --variant "$variant_name" \
    --trigger "$trigger" --pass-rate "$full_pass_rate" 2>/dev/null || true

  refined_count=$((refined_count + 1))
done

echo "Total: $refined_count template(s) processed."
