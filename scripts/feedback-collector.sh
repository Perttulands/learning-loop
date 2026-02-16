#!/usr/bin/env bash
# feedback-collector.sh - Extract feedback record from a run record
# Usage: ./scripts/feedback-collector.sh <run-record.json>
# Output: state/feedback/<bead>.json
# Env: FEEDBACK_DIR overrides output directory (default: state/feedback/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <run-record.json>" >&2
  exit 1
fi

RUN_FILE="$1"

if [[ ! -f "$RUN_FILE" ]]; then
  echo "Error: file not found: $RUN_FILE" >&2
  exit 1
fi

FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
mkdir -p "$FEEDBACK_DIR"

# Skip runs that are still in progress
status="$(jq -r '.status' "$RUN_FILE")"
if [[ "$status" == "running" ]]; then
  exit 0
fi

# Read run record fields
bead="$(jq -r '.bead' "$RUN_FILE")"
agent="$(jq -r '.agent // "unknown"' "$RUN_FILE")"
model="$(jq -r '.model // "unknown"' "$RUN_FILE")"
template="$(jq -r '.template_name // "custom"' "$RUN_FILE")"
prompt_hash="$(jq -r '.prompt_hash // ""' "$RUN_FILE")"
exit_code="$(jq -r '.exit_code // "null"' "$RUN_FILE")"
failure_reason="$(jq -r '.failure_reason // ""' "$RUN_FILE")"
attempt="$(jq -r '.attempt // 1' "$RUN_FILE")"
duration="$(jq -r '.duration_seconds // 0' "$RUN_FILE")"

# Extract verification signals
v_lint="$(jq -r '.verification.lint // "skipped"' "$RUN_FILE")"
v_tests="$(jq -r '.verification.tests // "skipped"' "$RUN_FILE")"
v_ubs="$(jq -r '.verification.ubs // "skipped"' "$RUN_FILE")"
v_truthsayer="$(jq -r '.verification.truthsayer // "skipped"' "$RUN_FILE")"

# Build signals
exit_clean=$([[ "$exit_code" == "0" ]] && echo true || echo false)
tests_pass=$([[ "$v_tests" == "pass" ]] && echo true || echo false)
lint_pass=$([[ "$v_lint" == "pass" ]] && echo true || echo false)
ubs_clean=$([[ "$v_ubs" == "clean" ]] && echo true || echo false)
truthsayer_clean=$([[ "$v_truthsayer" == "pass" ]] && echo true || echo false)
retried=$([[ "$attempt" -gt 1 ]] && echo true || echo false)

# Duration ratio: actual / 600s baseline (10 min expected)
duration_num="${duration:-0}"
if [[ "$duration_num" == "null" ]]; then
  duration_num=0
fi
duration_ratio="$(echo "$duration_num / 600" | bc -l | sed 's/^\./0./')"

# Classify outcome
classify_outcome() {
  # Timeout
  if [[ "$status" == "timeout" ]]; then
    echo "timeout"
    return
  fi

  # Infra failure: known infra failure_reasons
  case "$failure_reason" in
    tmux-launch-failed|status-file|agent-died-work-preserved)
      echo "infra_failure"
      return
      ;;
  esac
  # Also treat disk/network failures as infra
  if [[ "$failure_reason" == infra-* ]]; then
    echo "infra_failure"
    return
  fi

  # Agent failure: non-zero exit or tests/ubs failed
  if [[ "$exit_clean" == "false" && "$status" == "done" ]]; then
    echo "agent_failure"
    return
  fi
  if [[ "$status" == "failed" ]]; then
    echo "agent_failure"
    return
  fi

  # Full pass: all non-skipped checks pass
  if [[ "$tests_pass" == "true" || "$v_tests" == "skipped" ]] && \
     [[ "$lint_pass" == "true" || "$v_lint" == "skipped" ]] && \
     [[ "$ubs_clean" == "true" ]] && \
     [[ "$truthsayer_clean" == "true" || "$v_truthsayer" == "skipped" ]] && \
     [[ "$exit_clean" == "true" ]]; then
    echo "full_pass"
    return
  fi

  # Partial pass: done with some checks failing
  echo "partial_pass"
}

outcome="$(classify_outcome)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Detect failure patterns
failure_patterns="$("$SCRIPT_DIR/detect-patterns.sh" --update-registry "$RUN_FILE")"

# Build feedback JSON
jq -n \
  --arg schema_version "1.0.0" \
  --arg bead "$bead" \
  --arg timestamp "$timestamp" \
  --arg template "$template" \
  --arg agent "$agent" \
  --arg model "$model" \
  --arg outcome "$outcome" \
  --argjson exit_clean "$exit_clean" \
  --argjson tests_pass "$tests_pass" \
  --argjson lint_pass "$lint_pass" \
  --argjson ubs_clean "$ubs_clean" \
  --argjson truthsayer_clean "$truthsayer_clean" \
  --argjson duration_ratio "$duration_ratio" \
  --argjson retried "$retried" \
  --arg prompt_hash "$prompt_hash" \
  --argjson failure_patterns "$failure_patterns" \
  '{
    schema_version: $schema_version,
    bead: $bead,
    timestamp: $timestamp,
    template: $template,
    agent: $agent,
    model: $model,
    outcome: $outcome,
    signals: {
      exit_clean: $exit_clean,
      tests_pass: $tests_pass,
      lint_pass: $lint_pass,
      ubs_clean: $ubs_clean,
      truthsayer_clean: $truthsayer_clean,
      duration_ratio: $duration_ratio,
      retried: $retried
    },
    failure_patterns: $failure_patterns,
    prompt_hash: $prompt_hash
  }' > "$FEEDBACK_DIR/$bead.json"
