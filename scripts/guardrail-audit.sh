#!/usr/bin/env bash
# guardrail-audit.sh - Run guardrail smoke audit and emit JSON report
# Usage: SCORES_DIR=... FEEDBACK_DIR=... REPORTS_DIR=... ./scripts/guardrail-audit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/state/reports}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0"
  echo "Runs a guardrail smoke audit and writes guardrail-audit-*.json"
  echo "Env vars: SCORES_DIR, FEEDBACK_DIR, REPORTS_DIR"
  exit 0
fi

mkdir -p "$REPORTS_DIR"

GUARDRAILS_SCRIPT="$SCRIPT_DIR/guardrails.sh"
if [[ ! -x "$GUARDRAILS_SCRIPT" ]]; then
  echo "Error: guardrails.sh not executable at $GUARDRAILS_SCRIPT" >&2
  exit 1
fi

run_check() {
  local id="$1" cmd="$2"
  local output
  output="$(SCORES_DIR="$SCORES_DIR" FEEDBACK_DIR="$FEEDBACK_DIR" AB_TESTS_FILE="${AB_TESTS_FILE:-$SCORES_DIR/ab-tests.json}" REFINEMENT_LOG="${REFINEMENT_LOG:-$SCORES_DIR/refinement-log.json}" bash -lc "$cmd" 2>&1 || true)" # REASON: Audit should capture failing command output instead of aborting at first failure.

  jq -n --arg id "$id" --arg command "$cmd" --arg output "$output" '{id: $id, command: $command, output: $output}'
}

checks_json="$(jq -n --argjson c1 "$(run_check 'variant_limit' "'$GUARDRAILS_SCRIPT' check-variant-limit custom")" \
  --argjson c2 "$(run_check 'sample_scoring' "'$GUARDRAILS_SCRIPT' check-sample-size 4 scoring")" \
  --argjson c3 "$(run_check 'sample_refinement' "'$GUARDRAILS_SCRIPT' check-sample-size 10 refinement")" \
  --argjson c4 "$(run_check 'rollback_check' "'$GUARDRAILS_SCRIPT' check-rollback")" \
  --argjson c5 "$(run_check 'refinement_loop' "'$GUARDRAILS_SCRIPT' check-refinement-loop custom")" \
  --argjson c6 "$(run_check 'duplicate_detection' "'$GUARDRAILS_SCRIPT' check-duplicates custom")" \
  '{checks: [$c1,$c2,$c3,$c4,$c5,$c6]}')"

passed="$(echo "$checks_json" | jq '[.checks[] | select(.output | length > 0)] | length')"
total="$(echo "$checks_json" | jq '.checks | length')"

report="$(jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson checks "$(echo "$checks_json" | jq '.checks')" \
  --argjson passed "$passed" \
  --argjson total "$total" \
  '{
    schema_version: "1.0.0",
    generated_at: $ts,
    summary: {
      checks_run: $total,
      checks_with_output: $passed
    },
    checks: $checks
  }')"

report_file="$REPORTS_DIR/guardrail-audit-$(date -u +%Y%m%dT%H%M%SZ).json"
echo "$report" > "$report_file"

echo "Guardrail audit report written to: $report_file"
