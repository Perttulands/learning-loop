#!/usr/bin/env bash
# ab-tests.sh - A/B test lifecycle management for template variants
# Usage: ./scripts/ab-tests.sh <subcommand> [args]
# Subcommands: create, pick, record, evaluate, list, review-queue, approve
# Env: SCORES_DIR, TEMPLATES_DIR, AB_TESTS_FILE, REFINEMENT_LOG, REVIEW_QUEUE_FILE, NO_AUTO_PROMOTE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$PROJECT_DIR/templates}"
AB_TESTS_FILE="${AB_TESTS_FILE:-$SCORES_DIR/ab-tests.json}"
REFINEMENT_LOG="${REFINEMENT_LOG:-$SCORES_DIR/refinement-log.json}"
REVIEW_QUEUE_FILE="${REVIEW_QUEUE_FILE:-$SCORES_DIR/promotion-review-queue.json}"
NO_AUTO_PROMOTE="${NO_AUTO_PROMOTE:-false}"

usage() {
  echo "Usage: $0 <subcommand> [args]"
  echo "Subcommands:"
  echo "  create <original> <variant> [--target-runs N]  Start a new A/B test"
  echo "  pick <template>                                Get which template to use next"
  echo "  record <template> <original|variant>           Record a dispatch run"
  echo "  evaluate                                       Evaluate all ready tests"
  echo "  list                                           List all A/B tests"
  echo "  review-queue                                   List pending gated promotions"
  echo "  approve <original>                             Approve and promote a queued variant"
  echo "  --help                                         Show this message"
}

# Ensure ab-tests.json exists
ensure_file() {
  mkdir -p "$(dirname "$AB_TESTS_FILE")"
  if [[ ! -f "$AB_TESTS_FILE" ]]; then
    echo '{"schema_version":"1.0.0","tests":[]}' > "$AB_TESTS_FILE"
  fi
}

ensure_review_queue() {
  mkdir -p "$(dirname "$REVIEW_QUEUE_FILE")"
  if [[ ! -f "$REVIEW_QUEUE_FILE" ]]; then
    echo '{"schema_version":"1.0.0","entries":[]}' > "$REVIEW_QUEUE_FILE"
  fi
}

# Create a new A/B test
cmd_create() {
  local original="$1" variant="$2"
  shift 2
  local target_runs=10

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-runs) target_runs="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  ensure_file

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg orig "$original" --arg var "$variant" \
     --argjson target "$target_runs" --arg ts "$ts" \
    '.tests += [{
      original: $orig,
      variant: $var,
      status: "active",
      target_runs: $target,
      original_runs: 0,
      variant_runs: 0,
      created_at: $ts
    }]' "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

  # Enforce variant limit
  local guardrails="$SCRIPT_DIR/guardrails.sh"
  if [[ -x "$guardrails" ]]; then
    "$guardrails" enforce-variant-limit "$original" 2>/dev/null || true # REASON: Guardrail checks are advisory and must not block A/B test creation.
  fi

  echo "Created A/B test: $original vs $variant (target: $target_runs runs each)"
}

# Pick which template to dispatch for alternation
cmd_pick() {
  local template="$1"

  if [[ ! -f "$AB_TESTS_FILE" ]]; then
    jq -n --arg t "$template" \
      '{template: $t, ab_test: false}'
    return
  fi

  local test_data
  test_data="$(jq --arg t "$template" \
    '[.tests[] | select(.status == "active" and .original == $t)] |
     if length > 0 then .[0] else null end' "$AB_TESTS_FILE")"

  if [[ "$test_data" == "null" ]]; then
    jq -n --arg t "$template" \
      '{template: $t, ab_test: false}'
    return
  fi

  local orig_runs variant_runs original variant
  orig_runs="$(echo "$test_data" | jq '.original_runs')"
  variant_runs="$(echo "$test_data" | jq '.variant_runs')"
  original="$(echo "$test_data" | jq -r '.original')"
  variant="$(echo "$test_data" | jq -r '.variant')"

  # Alternate: use whichever has fewer runs (original first on tie)
  local pick_template
  if [[ "$orig_runs" -le "$variant_runs" ]]; then
    pick_template="$original"
  else
    pick_template="$variant"
  fi

  jq -n --arg t "$pick_template" --arg orig "$original" --arg var "$variant" \
    '{template: $t, ab_test: true, original: $orig, variant: $var}'
}

# Record a dispatch run for a template
cmd_record() {
  local template="$1" side="$2"  # side: "original" or "variant"

  ensure_file

  if [[ "$side" == "original" ]]; then
    jq --arg t "$template" \
      '(.tests[] | select(.status == "active" and .original == $t)).original_runs += 1' \
      "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  else
    jq --arg t "$template" \
      '(.tests[] | select(.status == "active" and .original == $t)).variant_runs += 1' \
      "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  fi
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"
}

promote_variant() {
  local orig="$1" var="$2" orig_score="$3" var_score="$4"
  local decision="promoted"

  echo "Promoted: $var (score: $var_score) beats $orig (score: $orig_score)"

  "$SCRIPT_DIR/notify.sh" variant-promoted \
    --variant "$var" --original "$orig" \
    --variant-score "$var_score" --original-score "$orig_score" 2>/dev/null || true # REASON: Notification failures must not break promotion flow.

  mkdir -p "$TEMPLATES_DIR/.archive"
  if [[ -f "$TEMPLATES_DIR/${orig}.md" ]]; then
    cp "$TEMPLATES_DIR/${orig}.md" "$TEMPLATES_DIR/.archive/${orig}-pre-${var}.md"
    mv "$TEMPLATES_DIR/${orig}.md" "$TEMPLATES_DIR/.archive/${orig}.md"
  fi
  if [[ -f "$TEMPLATES_DIR/${var}.md" ]]; then
    cp "$TEMPLATES_DIR/${var}.md" "$TEMPLATES_DIR/${orig}.md"
    mv "$TEMPLATES_DIR/${var}.md" "$TEMPLATES_DIR/.archive/${var}.md"
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg orig "$orig" --arg decision "$decision" --arg ts "$ts" \
    '(.tests[] | select(.status == "active" and .original == $orig)) |=
      (.status = "completed" | .decision = $decision | .completed_at = $ts)' \
    "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

  log_decision "$orig" "$var" "$decision" "$orig_score" "$var_score"
}

queue_promotion() {
  local orig="$1" var="$2" orig_score="$3" var_score="$4" diff="$5"
  ensure_review_queue

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg orig "$orig" --arg var "$var" \
     --argjson os "$orig_score" --argjson vs "$var_score" --argjson d "$diff" --arg ts "$ts" \
    '.entries += [{
      original: $orig,
      variant: $var,
      original_score: $os,
      variant_score: $vs,
      score_diff: $d,
      status: "pending",
      queued_at: $ts
    }]' "$REVIEW_QUEUE_FILE" > "$REVIEW_QUEUE_FILE.tmp"
  mv "$REVIEW_QUEUE_FILE.tmp" "$REVIEW_QUEUE_FILE"

  local complete_ts
  complete_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg orig "$orig" --arg ts "$complete_ts" \
    '(.tests[] | select(.status == "active" and .original == $orig)) |=
      (.status = "completed" | .decision = "gated" | .completed_at = $ts)' \
    "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

  log_decision "$orig" "$var" "gated" "$orig_score" "$var_score"
}

# Evaluate all active tests that have reached target_runs
cmd_evaluate() {
  ensure_file

  local scores_file="$SCORES_DIR/template-scores.json"
  if [[ ! -f "$scores_file" ]]; then
    echo "No template-scores.json found" >&2
    return
  fi

  local active_tests
  active_tests="$(jq '[.tests[] | select(.status == "active")]' "$AB_TESTS_FILE")"
  local count
  count="$(echo "$active_tests" | jq 'length')"

  if [[ "$count" -eq 0 ]]; then
    echo "No active A/B tests to evaluate."
    return
  fi

  local i=0
  while [[ $i -lt $count ]]; do
    local test_entry
    test_entry="$(echo "$active_tests" | jq ".[$i]")"

    local orig var target orig_runs var_runs
    orig="$(echo "$test_entry" | jq -r '.original')"
    var="$(echo "$test_entry" | jq -r '.variant')"
    target="$(echo "$test_entry" | jq '.target_runs')"
    orig_runs="$(echo "$test_entry" | jq '.original_runs')"
    var_runs="$(echo "$test_entry" | jq '.variant_runs')"

    if [[ "$orig_runs" -lt "$target" ]] || [[ "$var_runs" -lt "$target" ]]; then
      echo "Test $orig vs $var: not ready (${orig_runs}/${target} original, ${var_runs}/${target} variant)"
      i=$((i + 1))
      continue
    fi

    # Get scores for both
    local orig_score var_score
    orig_score="$(jq --arg t "$orig" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].score else 0 end' \
      "$scores_file")"
    var_score="$(jq --arg t "$var" \
      '[.templates[] | select(.template == $t)] | if length > 0 then .[0].score else 0 end' \
      "$scores_file")"

    local diff decision
    diff="$(echo "$var_score - $orig_score" | bc -l)"

    # Promote if variant > original by >= 0.1
    if echo "$diff >= 0.1" | bc -l | grep -q '^1'; then
      if [[ "$NO_AUTO_PROMOTE" == "true" ]]; then
        echo "Promotion gated: $var (score: $var_score) beats $orig (score: $orig_score) by $diff. Added to review queue."
        queue_promotion "$orig" "$var" "$orig_score" "$var_score" "$diff"
        i=$((i + 1))
        continue
      fi

      decision="promoted"
      promote_variant "$orig" "$var" "$orig_score" "$var_score"
      i=$((i + 1))
      continue
    else
      decision="discarded"
      echo "Discarded: $var (score: $var_score) did not beat $orig (score: $orig_score) by >= 0.1"

      # Notify: variant discarded
      "$SCRIPT_DIR/notify.sh" variant-discarded \
        --variant "$var" --original "$orig" \
        --variant-score "$var_score" --original-score "$orig_score" 2>/dev/null || true # REASON: Notification failures must not break evaluation flow.

      # Archive variant
      mkdir -p "$TEMPLATES_DIR/.archive"
      if [[ -f "$TEMPLATES_DIR/${var}.md" ]]; then
        mv "$TEMPLATES_DIR/${var}.md" "$TEMPLATES_DIR/.archive/${var}.md"
      fi
    fi

    # Update test status
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg orig "$orig" --arg decision "$decision" --arg ts "$ts" \
      '(.tests[] | select(.status == "active" and .original == $orig)) |=
        (.status = "completed" | .decision = $decision | .completed_at = $ts)' \
      "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
    mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

    # Log to refinement-log.json
    log_decision "$orig" "$var" "$decision" "$orig_score" "$var_score"

    i=$((i + 1))
  done
}

# Log decision to refinement-log.json
log_decision() {
  local orig="$1" var="$2" decision="$3" orig_score="$4" var_score="$5"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local entry
  entry="$(jq -n --arg orig "$orig" --arg var "$var" --arg decision "$decision" \
    --argjson orig_score "$orig_score" --argjson var_score "$var_score" --arg ts "$ts" \
    '{
      type: "ab_test_result",
      original: $orig,
      variant: $var,
      decision: $decision,
      original_score: $orig_score,
      variant_score: $var_score,
      timestamp: $ts
    }')"

  mkdir -p "$(dirname "$REFINEMENT_LOG")"
  if [[ -f "$REFINEMENT_LOG" ]]; then
    jq --argjson entry "$entry" '.entries += [$entry]' "$REFINEMENT_LOG" > "$REFINEMENT_LOG.tmp"
    mv "$REFINEMENT_LOG.tmp" "$REFINEMENT_LOG"
  else
    echo "$entry" | jq '{schema_version: "1.0.0", entries: [.]}' > "$REFINEMENT_LOG"
  fi
}

# List all A/B tests
cmd_list() {
  if [[ ! -f "$AB_TESTS_FILE" ]]; then
    echo "No A/B tests found."
    return
  fi

  local count
  count="$(jq '.tests | length' "$AB_TESTS_FILE")"

  if [[ "$count" -eq 0 ]]; then
    echo "No A/B tests found."
    return
  fi

  jq -r '.tests[] | "\(.original) vs \(.variant) | status: \(.status) | runs: \(.original_runs)/\(.target_runs) orig, \(.variant_runs)/\(.target_runs) var"' "$AB_TESTS_FILE"
}

cmd_review_queue() {
  ensure_review_queue

  local pending
  pending="$(jq '[.entries[] | select(.status == "pending")]' "$REVIEW_QUEUE_FILE")"
  local count
  count="$(echo "$pending" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    echo "No pending promotion reviews."
    return
  fi

  echo "$pending" | jq -r '.[] | "\(.original) vs \(.variant) | diff: \(.score_diff) | queued: \(.queued_at)"'
}

cmd_approve() {
  local original="$1"
  ensure_review_queue
  ensure_file

  local entry
  entry="$(jq --arg o "$original" \
    '[.entries[] | select(.status == "pending" and .original == $o)] | if length > 0 then .[0] else null end' \
    "$REVIEW_QUEUE_FILE")"

  if [[ "$entry" == "null" ]]; then
    echo "No pending review entry for $original" >&2
    return 1
  fi

  local variant orig_score var_score
  variant="$(echo "$entry" | jq -r '.variant')"
  orig_score="$(echo "$entry" | jq '.original_score')"
  var_score="$(echo "$entry" | jq '.variant_score')"

  promote_variant "$original" "$variant" "$orig_score" "$var_score"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg o "$original" --arg ts "$ts" \
    '(.tests[] | select(.original == $o and .decision == "gated")) |=
      (.decision = "promoted" | .completed_at = $ts)' \
    "$AB_TESTS_FILE" > "$AB_TESTS_FILE.tmp"
  mv "$AB_TESTS_FILE.tmp" "$AB_TESTS_FILE"

  jq --arg o "$original" --arg ts "$ts" \
    '(.entries[] | select(.status == "pending" and .original == $o)) |=
      (.status = "approved" | .resolved_at = $ts)' \
    "$REVIEW_QUEUE_FILE" > "$REVIEW_QUEUE_FILE.tmp"
  mv "$REVIEW_QUEUE_FILE.tmp" "$REVIEW_QUEUE_FILE"
}

# Main dispatch
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  create)
    shift
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 create <original> <variant> [--target-runs N]" >&2
      exit 1
    fi
    cmd_create "$@"
    ;;
  pick)
    shift
    if [[ $# -lt 1 ]]; then
      echo "Usage: $0 pick <template>" >&2
      exit 1
    fi
    cmd_pick "$1"
    ;;
  record)
    shift
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 record <template> <original|variant>" >&2
      exit 1
    fi
    cmd_record "$1" "$2"
    ;;
  evaluate)
    cmd_evaluate
    ;;
  list)
    cmd_list
    ;;
  review-queue)
    cmd_review_queue
    ;;
  approve)
    shift
    if [[ $# -lt 1 ]]; then
      echo "Usage: $0 approve <original>" >&2
      exit 1
    fi
    cmd_approve "$1"
    ;;
  --help|-h)
    usage
    ;;
  *)
    echo "Unknown subcommand: $1" >&2
    usage
    exit 1
    ;;
esac
