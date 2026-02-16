#!/usr/bin/env bash
# select-template.sh - Recommend template and agent for a task
# Usage: ./scripts/select-template.sh "<task description>"
# Output: JSON with template, variant, agent, model, score, confidence, reasoning, warnings
# Env: SCORES_DIR overrides scores directory (default: state/scores/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"<task description>\"" >&2
  exit 1
fi

TASK="$1"
SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
SCORES_FILE="$SCORES_DIR/template-scores.json"

# Classify task type from keywords
classify_task() {
  local task_lower
  task_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$task_lower" in
    *fix*|*bug*|*debug*) echo "bug-fix" ;;
    *add*|*create*|*implement*) echo "feature" ;;
    *refactor*) echo "refactor" ;;
    *doc*) echo "docs" ;;
    *script*) echo "script" ;;
    *review*) echo "code-review" ;;
    *) echo "custom" ;;
  esac
}

task_type="$(classify_task "$TASK")"

# If no scores file, return fallback
if [[ ! -f "$SCORES_FILE" ]]; then
  jq -n \
    --arg task_type "$task_type" \
    --arg task "$TASK" \
    '{
      template: "custom",
      variant: null,
      agent: "unknown",
      model: "unknown",
      task_type: $task_type,
      score: 0,
      confidence: "none",
      reasoning: ("No scores data available. Task classified as " + $task_type + "."),
      warnings: ["No template-scores.json found — using defaults"]
    }'
  exit 0
fi

# Look up matching template and pick best agent
jq --arg task_type "$task_type" --arg task "$TASK" '
  # Find matching template (null if not found)
  ([.templates[] | select(.template == $task_type)] | if length > 0 then .[0] else null end) as $match |

  # Warnings accumulator
  ([] |
    if $match == null then . + ["No score data for template: " + $task_type]
    elif $match.confidence == "low" then . + ["Low confidence (" + ($match.total_runs | tostring) + " runs) for template: " + $task_type]
    else . end
  ) as $warnings |

  # Template info
  (if $match then $match.template else $task_type end) as $template |
  (if $match then $match.score else 0 end) as $score |
  (if $match then $match.confidence else "none" end) as $confidence |

  # Agent recommendation: highest full_pass_rate with min 3 runs
  (if $match then
    [$match.agents[] | select(.total_runs >= 3)] |
    sort_by(-.full_pass_rate) |
    if length > 0 then .[0].agent else "unknown" end
  else "unknown" end) as $agent |

  # Reasoning
  (if $match then
    "Template " + $template + " has score " + ($score | tostring) +
    " (" + $confidence + " confidence). Agent " + $agent + " recommended."
  else
    "No scores data for " + $task_type + ". Task classified as " + $task_type + "."
  end) as $reasoning |

  {
    template: $template,
    variant: null,
    agent: $agent,
    model: "unknown",
    task_type: $task_type,
    score: $score,
    confidence: $confidence,
    reasoning: $reasoning,
    warnings: $warnings
  }
' "$SCORES_FILE"
