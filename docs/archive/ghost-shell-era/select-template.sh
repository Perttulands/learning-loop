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
  local task_lower best_template best_score tpl
  declare -A score

  score["bug-fix"]=0
  score["feature"]=0
  score["refactor"]=0
  score["docs"]=0
  score["script"]=0
  score["code-review"]=0

  task_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

  add_score() {
    local key="$1" amount="$2"
    score["$key"]=$((score["$key"] + amount))
  }

  # Bug-fix / debugging signals
  [[ "$task_lower" =~ (fix|bug|debug|regression|crash|failing\ test|error|incident|hotfix|broken) ]] && add_score "bug-fix" 4
  [[ "$task_lower" =~ (investigate|root\ cause|why\ does|repair|resolve) ]] && add_score "bug-fix" 2

  # Feature delivery signals
  [[ "$task_lower" =~ (add|create|implement|build|introduce|support|new\ endpoint|new\ api|feature\ flag) ]] && add_score "feature" 3
  [[ "$task_lower" =~ (workflow|integration|pipeline|capability|enable|allow\ users\ to) ]] && add_score "feature" 2

  # Refactor / cleanup signals
  [[ "$task_lower" =~ (refactor|cleanup|clean\ up|simplify|restructure|reorganize|rename|extract) ]] && add_score "refactor" 4
  [[ "$task_lower" =~ (tech\ debt|maintainability|readability|modularize) ]] && add_score "refactor" 2
  [[ "$task_lower" =~ (reduce\ tech\ debt|debt\ reduction) ]] && add_score "refactor" 2

  # Documentation signals
  [[ "$task_lower" =~ (doc|documentation|readme|changelog|guide|tutorial|comment) ]] && add_score "docs" 4
  [[ "$task_lower" =~ (api\ docs|usage\ examples|how\ to) ]] && add_score "docs" 2
  [[ "$task_lower" =~ (^add|^update|^write).*(guide|docs|documentation|readme|comment|changelog) ]] && add_score "docs" 3

  # Script/automation signals
  [[ "$task_lower" =~ (script|bash|shell|cron|automation|automate|cli\ tool|job\ runner) ]] && add_score "script" 4
  [[ "$task_lower" =~ (scheduled|scheduler|task\ runner) ]] && add_score "script" 2

  # Review/audit signals
  [[ "$task_lower" =~ (review|audit|assess|analyze|inspection|code\ review|risk\ analysis) ]] && add_score "code-review" 4
  [[ "$task_lower" =~ (findings|severity|regression\ risk|threat\ model) ]] && add_score "code-review" 2

  # Structure-aware tie breakers
  [[ "$task_lower" =~ (^fix|^debug|^repair) ]] && add_score "bug-fix" 2
  [[ "$task_lower" =~ (^add|^implement|^create) ]] && add_score "feature" 2
  [[ "$task_lower" =~ (^refactor|^cleanup) ]] && add_score "refactor" 2
  [[ "$task_lower" =~ (^document|^write\ docs|^update\ readme) ]] && add_score "docs" 2
  [[ "$task_lower" =~ (^write\ a\ script|^create\ a\ script|^automate) ]] && add_score "script" 2
  [[ "$task_lower" =~ (^review|^audit) ]] && add_score "code-review" 2

  # Explicit docs + script can be ambiguous (doc generation script). Bias to script when automation is present.
  if [[ "${score["docs"]}" -gt 0 && "${score["script"]}" -gt 0 && "$task_lower" =~ (automate|script|generator) ]]; then
    add_score "script" 1
  fi

  # Structure-aware disambiguation between feature and script/doc requests.
  if [[ "${score["feature"]}" -gt 0 && "${score["script"]}" -gt 0 && "$task_lower" =~ (bash|script|automation|cron|runner) ]]; then
    add_score "script" 2
  fi
  if [[ "${score["feature"]}" -gt 0 && "${score["docs"]}" -gt 0 && "$task_lower" =~ (guide|documentation|docs|readme|comment|changelog) ]]; then
    add_score "docs" 2
  fi

  # Planning/meta tasks should fall back to custom unless explicit implementation keywords dominate.
  if [[ "$task_lower" =~ (estimate\ effort|roadmap|brainstorm|stakeholder\ update|initiative|planning) ]]; then
    add_score "feature" -3
    add_score "bug-fix" -2
    add_score "refactor" -2
    add_score "docs" -1
    add_score "script" -2
    add_score "code-review" -1
  fi

  best_template="custom"
  best_score=0
  for tpl in bug-fix feature refactor docs script code-review; do
    if [[ "${score[$tpl]}" -gt "$best_score" ]]; then
      best_template="$tpl"
      best_score="${score[$tpl]}"
    fi
  done

  echo "$best_template"
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

# Check for active A/B test and get pick
AB_SCRIPT="$SCRIPT_DIR/ab-tests.sh"
ab_pick=""
if [[ -x "$AB_SCRIPT" ]]; then
  ab_pick="$("$AB_SCRIPT" pick "$task_type" 2>/dev/null || true)" # REASON: A/B pick is advisory; selection must still work if A/B state is unavailable.
fi

# Look up matching template and pick best agent
jq --arg task_type "$task_type" --arg task "$TASK" --argjson ab_pick "${ab_pick:-null}" '
  # Find matching template (null if not found)
  ([.templates[] | select(.template == $task_type)] | if length > 0 then .[0] else null end) as $match |

  # Warnings accumulator
  ([] |
    if $match == null then . + ["No score data for template: " + $task_type]
    elif $match.confidence == "low" then . + ["Low confidence (" + ($match.total_runs | tostring) + " runs) for template: " + $task_type]
    else . end
  ) as $warnings |

  # Template info (A/B test may override)
  (if $ab_pick != null and $ab_pick.ab_test == true then $ab_pick.template
   elif $match then $match.template else $task_type end) as $template |
  (if $ab_pick != null and $ab_pick.ab_test == true then $ab_pick.variant
   else null end) as $variant |
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
    variant: $variant,
    agent: $agent,
    model: "unknown",
    task_type: $task_type,
    score: $score,
    confidence: $confidence,
    reasoning: $reasoning,
    warnings: $warnings
  }
' "$SCORES_FILE"
