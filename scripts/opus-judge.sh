#!/usr/bin/env bash
# opus-judge.sh - Generate qualitative quality judgment for a run record
# Usage: ./scripts/opus-judge.sh <run-record.json>
# Env: JUDGE_MODEL (default: opus), JUDGE_MODE (heuristic|command), JUDGE_COMMAND (for command mode)
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 <run-record.json>"
  echo "Outputs judge JSON with quality_score, ratings, verdict, critique, findings."
  echo "Env: JUDGE_MODEL, JUDGE_MODE, JUDGE_COMMAND"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <run-record.json>" >&2
  exit 1
fi

RUN_FILE="$1"
if [[ ! -f "$RUN_FILE" ]]; then
  echo "Error: run record not found: $RUN_FILE" >&2
  exit 1
fi

JUDGE_MODEL="${JUDGE_MODEL:-opus}"
JUDGE_MODE="${JUDGE_MODE:-heuristic}"

bead="$(jq -r '.bead // "unknown"' "$RUN_FILE")"
status="$(jq -r '.status // "unknown"' "$RUN_FILE")"
agent="$(jq -r '.agent // "unknown"' "$RUN_FILE")"
model="$(jq -r '.model // "unknown"' "$RUN_FILE")"
template="$(jq -r '.template_name // .template // "custom"' "$RUN_FILE")"
exit_code="$(jq -r '.exit_code // "null"' "$RUN_FILE")"
tests="$(jq -r '.verification.tests // "skipped"' "$RUN_FILE")"
lint="$(jq -r '.verification.lint // "skipped"' "$RUN_FILE")"
ubs="$(jq -r '.verification.ubs // "skipped"' "$RUN_FILE")"
truthsayer="$(jq -r '.verification.truthsayer // "skipped"' "$RUN_FILE")"

clamp_rating() {
  local value="$1"
  if (( value < 1 )); then
    echo 1
  elif (( value > 5 )); then
    echo 5
  else
    echo "$value"
  fi
}

compute_heuristic() {
  local correctness=3
  local style=3
  local maintainability=3
  local confidence="medium"

  if [[ "$status" == "timeout" ]]; then
    correctness=1
    confidence="low"
  elif [[ "$status" == "failed" ]]; then
    correctness=1
    maintainability=2
    confidence="low"
  fi

  if [[ "$exit_code" == "0" ]]; then
    correctness=$((correctness + 1))
  elif [[ "$exit_code" != "null" ]]; then
    correctness=$((correctness - 1))
  fi

  if [[ "$tests" == "pass" ]]; then
    correctness=$((correctness + 1))
  elif [[ "$tests" == "fail" ]]; then
    correctness=$((correctness - 2))
  fi

  if [[ "$lint" == "pass" ]]; then
    style=$((style + 1))
  elif [[ "$lint" == "fail" ]]; then
    style=$((style - 1))
  fi

  if [[ "$ubs" == "clean" ]]; then
    maintainability=$((maintainability + 1))
  elif [[ "$ubs" == "issues" ]]; then
    maintainability=$((maintainability - 1))
  fi

  if [[ "$truthsayer" == "pass" ]]; then
    maintainability=$((maintainability + 1))
  elif [[ "$truthsayer" == "fail" ]]; then
    maintainability=$((maintainability - 1))
  fi

  correctness="$(clamp_rating "$correctness")"
  style="$(clamp_rating "$style")"
  maintainability="$(clamp_rating "$maintainability")"

  local weighted
  weighted="$(echo "(0.5 * $correctness + 0.2 * $style + 0.3 * $maintainability) / 5" | bc -l)"
  local quality_score
  quality_score="$(printf '%.3f' "$weighted")"

  local verdict="partial"
  if echo "$quality_score >= 0.80" | bc -l | grep -q '^1'; then
    verdict="pass"
    confidence="high"
  elif echo "$quality_score < 0.45" | bc -l | grep -q '^1'; then
    verdict="fail"
    confidence="low"
  fi

  local findings
  findings="$(jq -n \
    --arg tests "$tests" \
    --arg lint "$lint" \
    --arg ubs "$ubs" \
    --arg truth "$truthsayer" \
    --arg status "$status" \
    '[
      (if $tests == "fail" then {severity: "major", title: "Tests failing", details: "Verification tests reported failure."} else empty end),
      (if $lint == "fail" then {severity: "minor", title: "Lint issues present", details: "Lint verification did not pass."} else empty end),
      (if $ubs == "issues" then {severity: "major", title: "UBS issues detected", details: "Undefined behavior sanitizer reported issues."} else empty end),
      (if $truth == "fail" then {severity: "minor", title: "Truthsayer violations", details: "Truthsayer checks reported problems."} else empty end),
      (if $status == "timeout" then {severity: "major", title: "Execution timeout", details: "Run exceeded configured time budget."} else empty end)
    ]')"

  local critique
  critique="$(jq -n \
    --arg template "$template" \
    --arg agent "$agent" \
    --arg model "$model" \
    --arg tests "$tests" \
    --arg lint "$lint" \
    --arg truth "$truthsayer" \
    --arg status "$status" \
    -r '"Run on template \($template) by \($agent)/\($model) finished with status=\($status), tests=\($tests), lint=\($lint), truthsayer=\($truth)."')"

  jq -n \
    --arg schema_version "1.0.0" \
    --arg bead "$bead" \
    --arg judged_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg judge_model "$JUDGE_MODEL" \
    --argjson quality_score "$quality_score" \
    --argjson style_rating "$style" \
    --argjson maintainability_rating "$maintainability" \
    --argjson correctness_rating "$correctness" \
    --arg confidence "$confidence" \
    --arg verdict "$verdict" \
    --arg critique "$critique" \
    --argjson findings "$findings" \
    --arg tests_status "$tests" \
    --arg lint_status "$lint" \
    '{
      schema_version: $schema_version,
      bead: $bead,
      judged_at: $judged_at,
      judge_model: $judge_model,
      quality_score: $quality_score,
      style_rating: $style_rating,
      maintainability_rating: $maintainability_rating,
      correctness_rating: $correctness_rating,
      confidence: $confidence,
      verdict: $verdict,
      critique: $critique,
      findings: $findings,
      input_summary: {
        tests_status: $tests_status,
        lint_status: $lint_status
      }
    }'
}

if [[ "$JUDGE_MODE" == "command" ]]; then
  if [[ -z "${JUDGE_COMMAND:-}" ]]; then
    echo "Error: JUDGE_MODE=command requires JUDGE_COMMAND" >&2
    exit 1
  fi
  # Caller-provided command must output JSON following opus-judge-output schema.
  # shellcheck disable=SC2086
  eval "$JUDGE_COMMAND" < "$RUN_FILE"
  exit 0
fi

compute_heuristic
