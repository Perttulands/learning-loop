#!/usr/bin/env bash
# manage-patterns.sh - Pattern registry management
# Usage: ./scripts/manage-patterns.sh <command> [args]
# Commands: list, detail <pattern>, mitigate <pattern> <description>, effectiveness <pattern>
# Env: REGISTRY_FILE, FEEDBACK_DIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REGISTRY_FILE="${REGISTRY_FILE:-$PROJECT_DIR/state/feedback/pattern-registry.json}"
FEEDBACK_DIR="${FEEDBACK_DIR:-$PROJECT_DIR/state/feedback}"

INFRA_PATTERNS="infra-tmux infra-disk"

is_infra_pattern() {
  local pattern="$1"
  for ip in $INFRA_PATTERNS; do
    [[ "$pattern" == "$ip" ]] && return 0
  done
  return 1
}

usage() {
  echo "Usage: $0 <command> [args]"
  echo "Commands:"
  echo "  list                                  List all patterns sorted by count"
  echo "  detail <pattern>                      Show detail for a pattern"
  echo "  mitigate <pattern> <description>      Record mitigation for a pattern"
  echo "  effectiveness <pattern>               Check mitigation effectiveness"
}

cmd_list() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "No patterns found. Registry not found: $REGISTRY_FILE"
    return
  fi

  local entries
  entries="$(jq -r 'to_entries | sort_by(-.value.count)' "$REGISTRY_FILE")"
  local len
  len="$(echo "$entries" | jq 'length')"

  if [[ "$len" -eq 0 ]]; then
    echo "No patterns recorded."
    return
  fi

  local i=0
  while [[ $i -lt $len ]]; do
    local name count last_seen tag=""
    name="$(echo "$entries" | jq -r ".[$i].key")"
    count="$(echo "$entries" | jq -r ".[$i].value.count")"
    last_seen="$(echo "$entries" | jq -r ".[$i].value.last_seen")"
    if is_infra_pattern "$name"; then
      tag=" [infra - excluded from template scoring]"
    fi
    echo "${name}  count=${count}  last_seen=${last_seen}${tag}"
    i=$((i + 1))
  done
}

cmd_detail() {
  local pattern="$1"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Error: registry not found: $REGISTRY_FILE" >&2
    return 1
  fi

  local entry
  entry="$(jq --arg p "$pattern" '.[$p] // null' "$REGISTRY_FILE")"

  if [[ "$entry" == "null" ]]; then
    echo "Error: pattern not found: $pattern" >&2
    return 1
  fi

  local count first_seen last_seen beads
  count="$(echo "$entry" | jq '.count')"
  first_seen="$(echo "$entry" | jq -r '.first_seen')"
  last_seen="$(echo "$entry" | jq -r '.last_seen')"
  beads="$(echo "$entry" | jq -r '.last_beads | join(", ")')"

  echo "Pattern: $pattern"
  echo "Count: $count"
  echo "First seen: $first_seen"
  echo "Last seen: $last_seen"
  echo "Recent beads: $beads"

  if is_infra_pattern "$pattern"; then
    echo "Note: infra pattern — excluded from template scoring"
  fi

  local mitigation
  mitigation="$(echo "$entry" | jq -r '.mitigation // ""')"
  if [[ -n "$mitigation" ]]; then
    local mitigated_at
    mitigated_at="$(echo "$entry" | jq -r '.mitigated_at // "unknown"')"
    echo "Mitigation: $mitigation (recorded $mitigated_at)"
  fi
}

cmd_mitigate() {
  local pattern="$1" description="$2"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Error: registry not found: $REGISTRY_FILE" >&2
    return 1
  fi

  local exists
  exists="$(jq --arg p "$pattern" 'has($p)' "$REGISTRY_FILE")"
  if [[ "$exists" != "true" ]]; then
    echo "Error: pattern not found: $pattern" >&2
    return 1
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg p "$pattern" --arg d "$description" --arg ts "$ts" '
    .[$p].mitigation = $d |
    .[$p].mitigated_at = $ts |
    .[$p].count_at_mitigation = .[$p].count
  ' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  echo "Mitigation recorded for $pattern: $description"
}

cmd_effectiveness() {
  local pattern="$1"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Error: registry not found: $REGISTRY_FILE" >&2
    return 1
  fi

  local entry
  entry="$(jq --arg p "$pattern" '.[$p] // null' "$REGISTRY_FILE")"

  if [[ "$entry" == "null" ]]; then
    echo "Error: pattern not found: $pattern" >&2
    return 1
  fi

  local mitigation
  mitigation="$(echo "$entry" | jq -r '.mitigation // ""')"

  if [[ -z "$mitigation" ]]; then
    echo "Pattern $pattern: no mitigation recorded."
    return
  fi

  local count_at count_now
  count_at="$(echo "$entry" | jq '.count_at_mitigation')"
  count_now="$(echo "$entry" | jq '.count')"
  local post_count=$((count_now - count_at))

  # Count post-mitigation feedback records that have this pattern
  shopt -s nullglob
  local files=("$FEEDBACK_DIR"/*.json)
  shopt -u nullglob

  local total_post=0 pattern_post=0
  if [[ ${#files[@]} -gt 0 ]]; then
    # Count records with bead field (feedback records only) and check for pattern
    local counts
    counts="$(jq -s --arg p "$pattern" --argjson cat "$count_at" '
      [.[] | select(.bead != null)] |
      {
        total: length,
        with_pattern: [.[] | select(.failure_patterns | if type == "array" then any(. == $p) else false end)] | length
      }
    ' "${files[@]}")"
    total_post="$(echo "$counts" | jq '.total')"
    pattern_post="$(echo "$counts" | jq '.with_pattern')"
  fi

  echo "Pattern: $pattern"
  echo "Mitigation: $mitigation"
  echo "Count at mitigation: $count_at"
  echo "Current count: $count_now"
  echo "Post-mitigation occurrences: $post_count"

  if [[ $total_post -gt 0 ]]; then
    local pct=$((pattern_post * 100 / total_post))
    echo "Post-mitigation occurrence rate: ${pct}% ($pattern_post of $total_post runs)"
  else
    echo "No post-mitigation feedback data available."
  fi
}

# Main dispatch
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  list)
    cmd_list ;;
  detail)
    shift
    if [[ $# -lt 1 ]]; then echo "Usage: $0 detail <pattern>" >&2; exit 1; fi
    cmd_detail "$1" ;;
  mitigate)
    shift
    if [[ $# -lt 2 ]]; then echo "Usage: $0 mitigate <pattern> <description>" >&2; exit 1; fi
    cmd_mitigate "$1" "$2" ;;
  effectiveness)
    shift
    if [[ $# -lt 1 ]]; then echo "Usage: $0 effectiveness <pattern>" >&2; exit 1; fi
    cmd_effectiveness "$1" ;;
  --help|-h)
    usage ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1 ;;
esac
