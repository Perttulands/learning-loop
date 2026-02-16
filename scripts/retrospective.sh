#!/usr/bin/env bash
# retrospective.sh - Compare pre-loop vs post-loop metrics
# Usage: FEEDBACK_DIR=path REPORTS_DIR=path ./scripts/retrospective.sh [--boundary YYYY-MM-DD]
# Env: FEEDBACK_DIR, REPORTS_DIR (defaults to project subdirs)
# Output: state/reports/retrospective.json + human-readable summary to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/state/reports}"

boundary=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "Usage: $0 [--boundary YYYY-MM-DD]"
      echo "Compare pre-loop vs post-loop metrics."
      echo ""
      echo "Options:"
      echo "  --boundary DATE  Split date (default: auto-detect from first non-custom template)"
      echo ""
      echo "Env vars: FEEDBACK_DIR, REPORTS_DIR"
      exit 0
      ;;
    --boundary)
      boundary="$2"
      shift 2
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$FEEDBACK_DIR" ]]; then
  echo "Error: feedback directory not found: $FEEDBACK_DIR" >&2
  exit 1
fi

mkdir -p "$REPORTS_DIR"

# Collect all feedback files
shopt -s nullglob
feedback_files=("$FEEDBACK_DIR"/*.json)
shopt -u nullglob

if [[ ${#feedback_files[@]} -eq 0 ]]; then
  echo "Retrospective: 0 feedback records found."
  exit 0
fi

# Merge all feedback records (filter out non-feedback files)
all_feedback="$(jq -s '[.[] | select(.bead != null)]' "${feedback_files[@]}")"

report="$(echo "$all_feedback" | jq --arg boundary "$boundary" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
def compute_metrics(records):
  (records | length) as $total |
  ([records[] | select(.outcome != "infra_failure")] | length) as $scoreable |
  if $scoreable == 0 then
    {total_runs: $total, scoreable_runs: 0, full_pass_rate: 0, partial_pass_rate: 0,
     retry_rate: 0, timeout_rate: 0, template_usage_rate: 0,
     outcome_breakdown: {}, top_failure_patterns: [], template_breakdown: []}
  else
    ([records[] | select(.outcome == "full_pass")] | length) as $fp |
    ([records[] | select(.outcome == "partial_pass")] | length) as $pp |
    ([records[] | select(.outcome == "timeout")] | length) as $to |
    ([records[] | select(.signals.retried == true)] | length) as $retried |
    ([records[] | select(.template != "custom")] | length) as $non_custom |
    ($fp / $scoreable) as $fp_rate |
    ($pp / $scoreable) as $pp_rate |
    ($retried / $total) as $retry_rate |
    ($to / $scoreable) as $to_rate |
    ($non_custom / $total) as $tpl_rate |

    # Outcome breakdown counts
    (reduce records[] as $r ({}; .[$r.outcome] = ((.[$r.outcome] // 0) + 1))) as $outcomes |

    # Top failure patterns
    ([records[] | .failure_patterns // [] | .[]] |
      group_by(.) | [.[] | {pattern: .[0], count: length}] | sort_by(-.count) | .[:5]
    ) as $patterns |

    # Per-template breakdown
    ([records[] | select(.template != "custom")] | group_by(.template) |
      [.[] | (.[0].template) as $t |
        ([.[] | select(.outcome == "full_pass")] | length) as $tfp |
        {template: $t, runs: length, full_pass_rate: ($tfp / length)}
      ] | sort_by(-.full_pass_rate)
    ) as $tpl_breakdown |

    {
      total_runs: $total,
      scoreable_runs: $scoreable,
      full_pass_rate: $fp_rate,
      partial_pass_rate: $pp_rate,
      retry_rate: $retry_rate,
      timeout_rate: $to_rate,
      template_usage_rate: $tpl_rate,
      outcome_breakdown: $outcomes,
      top_failure_patterns: $patterns,
      template_breakdown: $tpl_breakdown
    }
  end;

def threshold_tuning(pre; post):
  [
    # If pass rate improved a lot, refinement threshold could be raised
    if (post.full_pass_rate - pre.full_pass_rate) > 0.3 then
      "Pass rate improved by " + ((post.full_pass_rate - pre.full_pass_rate) * 100 | round | tostring) + "%. Consider raising refinement trigger from 0.50 to 0.60."
    else empty end,

    # If retry rate changed
    if pre.retry_rate > 0.1 and post.retry_rate < pre.retry_rate then
      "Retry rate dropped from " + (pre.retry_rate * 100 | round | tostring) + "% to " + (post.retry_rate * 100 | round | tostring) + "%. Current retry penalty (0.2) may be over-weighting."
    else empty end,

    # If template usage is high, increase confidence requirements
    if post.template_usage_rate > 0.5 then
      "Template usage at " + (post.template_usage_rate * 100 | round | tostring) + "%. Consider requiring high confidence for auto-selection."
    else empty end,

    # If certain patterns disappeared, mitigation is working
    if (pre.top_failure_patterns | length) > 0 and (post.top_failure_patterns | length) == 0 then
      "All pre-loop failure patterns eliminated. Review pattern detection thresholds."
    else empty end
  ];

# Auto-detect boundary: first non-custom template timestamp
(if $boundary != "" then $boundary
 else
   [.[] | select(.template != "custom") | .timestamp] |
   sort | if length > 0 then .[0][:10] else now | strftime("%Y-%m-%d") end
 end) as $split |

# Split records
([.[] | select(.timestamp < ($split + "T00:00:00Z"))] | sort_by(.timestamp)) as $pre |
([.[] | select(.timestamp >= ($split + "T00:00:00Z"))] | sort_by(.timestamp)) as $post |

compute_metrics($pre) as $pre_metrics |
compute_metrics($post) as $post_metrics |

{
  schema_version: "1.0.0",
  generated_at: $ts,
  boundary: $split,
  pre_loop: $pre_metrics,
  post_loop: $post_metrics,
  improvement: {
    pass_rate_delta: ($post_metrics.full_pass_rate - $pre_metrics.full_pass_rate),
    template_usage_delta: ($post_metrics.template_usage_rate - $pre_metrics.template_usage_rate),
    retry_rate_delta: ($post_metrics.retry_rate - $pre_metrics.retry_rate)
  },
  threshold_tuning: threshold_tuning($pre_metrics; $post_metrics)
}
')"

# Write report
echo "$report" > "$REPORTS_DIR/retrospective.json"

# Human-readable summary
pre_pr="$(echo "$report" | jq -r '.pre_loop.full_pass_rate * 100 | round')"
post_pr="$(echo "$report" | jq -r '.post_loop.full_pass_rate * 100 | round')"
pre_runs="$(echo "$report" | jq -r '.pre_loop.total_runs')"
post_runs="$(echo "$report" | jq -r '.post_loop.total_runs')"
boundary_used="$(echo "$report" | jq -r '.boundary')"

echo "Retrospective Report (boundary: $boundary_used)"
echo "  Pre-loop:  ${pre_runs} runs, ${pre_pr}% pass rate"
echo "  Post-loop: ${post_runs} runs, ${post_pr}% pass rate"
echo "  Delta:     pass rate +$(echo "$report" | jq -r '.improvement.pass_rate_delta * 100 | round')%"
echo "Report written to: $REPORTS_DIR/retrospective.json"
