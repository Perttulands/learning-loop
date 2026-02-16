#!/usr/bin/env bash
# detect-patterns.sh - Detect failure patterns from a run record
# Usage: ./scripts/detect-patterns.sh [--update-registry] <run-record.json>
# Output: JSON array of detected pattern names (to stdout)
# With --update-registry: also writes to pattern-registry.json
# Env: REGISTRY_FILE overrides registry path (default: state/feedback/pattern-registry.json)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UPDATE_REGISTRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-registry) UPDATE_REGISTRY=true; shift ;;
    -*) echo "Usage: $0 [--update-registry] <run-record.json>" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--update-registry] <run-record.json>" >&2
  exit 1
fi

RUN_FILE="$1"

if [[ ! -f "$RUN_FILE" ]]; then
  echo "Error: file not found: $RUN_FILE" >&2
  exit 1
fi

# Read fields from run record
status="$(jq -r '.status' "$RUN_FILE")"
exit_code="$(jq -r '.exit_code // "null"' "$RUN_FILE")"
failure_reason="$(jq -r '.failure_reason // ""' "$RUN_FILE")"
attempt="$(jq -r '.attempt // 1' "$RUN_FILE")"
duration="$(jq -r '.duration_seconds // 0' "$RUN_FILE")"

v_lint="$(jq -r '.verification.lint // "skipped"' "$RUN_FILE")"
v_tests="$(jq -r '.verification.tests // "skipped"' "$RUN_FILE")"
v_ubs="$(jq -r '.verification.ubs // "skipped"' "$RUN_FILE")"
v_truthsayer="$(jq -r '.verification.truthsayer // "skipped"' "$RUN_FILE")"

bead="$(jq -r '.bead // "unknown"' "$RUN_FILE")"

patterns=()

# 1. test-failure-after-completion: agent exited clean but tests fail
if [[ "$exit_code" == "0" && "$status" == "done" && "$v_tests" == "fail" ]]; then
  patterns+=("test-failure-after-completion")
fi

# 2. lint-failure-after-completion: agent exited clean but lint fails
if [[ "$exit_code" == "0" && "$status" == "done" && "$v_lint" == "fail" ]]; then
  patterns+=("lint-failure-after-completion")
fi

# 3. scope-creep: duration_ratio > 3.0 (took 3x longer than 600s baseline)
duration_num="${duration:-0}"
if [[ "$duration_num" == "null" ]]; then
  duration_num=0
fi
if [[ "$duration_num" -gt 1800 ]]; then
  patterns+=("scope-creep")
fi

# 4. incomplete-work: exit_code=0 but 2+ verifications fail
if [[ "$exit_code" == "0" && "$status" == "done" ]]; then
  fail_count=0
  [[ "$v_tests" == "fail" ]] && fail_count=$((fail_count + 1))
  [[ "$v_lint" == "fail" ]] && fail_count=$((fail_count + 1))
  [[ "$v_ubs" == "issues" ]] && fail_count=$((fail_count + 1))
  [[ "$v_truthsayer" == "fail" ]] && fail_count=$((fail_count + 1))
  if [[ "$fail_count" -ge 2 ]]; then
    patterns+=("incomplete-work")
  fi
fi

# 5. infra-tmux: tmux-related failure
if [[ "$failure_reason" == *tmux* ]]; then
  patterns+=("infra-tmux")
fi

# 6. infra-disk: disk-related failure
if [[ "$failure_reason" == *disk* ]]; then
  patterns+=("infra-disk")
fi

# 7. repeated-failure: attempt > 1
if [[ "$attempt" -gt 1 ]]; then
  patterns+=("repeated-failure")
fi

# 8. verification-gap: 2+ verification checks skipped (on a completed run)
if [[ "$status" == "done" ]]; then
  skip_count=0
  [[ "$v_tests" == "skipped" ]] && skip_count=$((skip_count + 1))
  [[ "$v_lint" == "skipped" ]] && skip_count=$((skip_count + 1))
  [[ "$v_ubs" == "skipped" ]] && skip_count=$((skip_count + 1))
  [[ "$v_truthsayer" == "skipped" ]] && skip_count=$((skip_count + 1))
  if [[ "$skip_count" -ge 2 ]]; then
    patterns+=("verification-gap")
  fi
fi

# Output as JSON array
if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${patterns[@]}" | jq -R . | jq -s .
fi

# Update pattern registry if requested
if [[ "$UPDATE_REGISTRY" == "true" ]]; then
  REGISTRY_FILE="${REGISTRY_FILE:-$PROJECT_DIR/state/feedback/pattern-registry.json}"
  registry_dir="$(dirname "$REGISTRY_FILE")"
  mkdir -p "$registry_dir"

  # Initialize registry if missing
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo '{}' > "$REGISTRY_FILE"
  fi

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  for pattern in "${patterns[@]}"; do
    # Increment count and append bead to last_beads
    jq --arg p "$pattern" --arg b "$bead" --arg ts "$timestamp" '
      if .[$p] then
        .[$p].count += 1 |
        .[$p].last_seen = $ts |
        .[$p].last_beads = (.[$p].last_beads + [$b] | .[-10:])
      else
        .[$p] = {
          count: 1,
          first_seen: $ts,
          last_seen: $ts,
          last_beads: [$b]
        }
      end
    ' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
    mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
  done
fi
