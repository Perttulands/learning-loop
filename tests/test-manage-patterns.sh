#!/usr/bin/env bash
# Tests for US-403: manage-patterns.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGE="$PROJECT_DIR/scripts/manage-patterns.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  FAIL: $desc (should NOT contain '$needle')"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

# === Test: Script exists and is executable ===
echo "=== Test: Script exists ==="
assert_eq "manage-patterns.sh exists" "true" \
  "$([ -f "$MANAGE" ] && echo true || echo false)"
assert_eq "manage-patterns.sh is executable" "true" \
  "$([ -x "$MANAGE" ] && echo true || echo false)"

# === Test: Usage message ===
echo ""
echo "=== Test: Usage ==="
usage_output="$("$MANAGE" 2>&1 || true)"
assert_contains "no args shows usage" "Usage" "$usage_output"
assert_contains "usage mentions list" "list" "$usage_output"
assert_contains "usage mentions detail" "detail" "$usage_output"
assert_contains "usage mentions mitigate" "mitigate" "$usage_output"
assert_contains "usage mentions effectiveness" "effectiveness" "$usage_output"

# --- Setup test registry ---
mkdir -p "$TMPDIR/feedback" "$TMPDIR/scores"
export REGISTRY_FILE="$TMPDIR/feedback/pattern-registry.json"
export FEEDBACK_DIR="$TMPDIR/feedback"
export SCORES_DIR="$TMPDIR/scores"

cat > "$REGISTRY_FILE" <<'EOF'
{
  "test-failure-after-completion": {
    "count": 37,
    "first_seen": "2026-01-01T00:00:00Z",
    "last_seen": "2026-02-15T12:00:00Z",
    "last_beads": ["bd-a1", "bd-a2", "bd-a3"]
  },
  "infra-tmux": {
    "count": 20,
    "first_seen": "2026-01-05T00:00:00Z",
    "last_seen": "2026-02-10T08:00:00Z",
    "last_beads": ["bd-b1", "bd-b2"]
  },
  "scope-creep": {
    "count": 5,
    "first_seen": "2026-01-10T00:00:00Z",
    "last_seen": "2026-02-01T00:00:00Z",
    "last_beads": ["bd-c1"]
  }
}
EOF

# === Test: list command ===
echo ""
echo "=== Test: list ==="
list_output="$("$MANAGE" list)"
assert_contains "list shows test-failure pattern" "test-failure-after-completion" "$list_output"
assert_contains "list shows infra-tmux" "infra-tmux" "$list_output"
assert_contains "list shows scope-creep" "scope-creep" "$list_output"
assert_contains "list shows count" "37" "$list_output"

# === Test: list sorted by count desc ===
echo ""
echo "=== Test: list sorted ==="
# test-failure (37) should appear before infra-tmux (20)
first_line="$(echo "$list_output" | head -1)"
assert_contains "most frequent pattern first" "test-failure-after-completion" "$first_line"

# === Test: detail command ===
echo ""
echo "=== Test: detail ==="
detail_output="$("$MANAGE" detail test-failure-after-completion)"
assert_contains "detail shows pattern name" "test-failure-after-completion" "$detail_output"
assert_contains "detail shows count" "37" "$detail_output"
assert_contains "detail shows first_seen" "2026-01-01" "$detail_output"
assert_contains "detail shows last_seen" "2026-02-15" "$detail_output"
assert_contains "detail shows bead" "bd-a1" "$detail_output"

# === Test: detail for unknown pattern ===
echo ""
echo "=== Test: detail unknown ==="
detail_unknown="$("$MANAGE" detail nonexistent-pattern 2>&1 || true)"
assert_contains "unknown pattern shows error" "not found" "$detail_unknown"

# === Test: mitigate command ===
echo ""
echo "=== Test: mitigate ==="
"$MANAGE" mitigate test-failure-after-completion "Added test verification step to prompt"
mitigated="$(jq -r '.["test-failure-after-completion"].mitigation' "$REGISTRY_FILE")"
assert_eq "mitigation recorded" "Added test verification step to prompt" "$mitigated"

mitigated_at="$(jq -r '.["test-failure-after-completion"].mitigated_at' "$REGISTRY_FILE")"
assert_eq "mitigated_at has timestamp" "true" \
  "$([ "$mitigated_at" != "null" ] && echo true || echo false)"

# Count at mitigation recorded
mitigated_count="$(jq '.["test-failure-after-completion"].count_at_mitigation' "$REGISTRY_FILE")"
assert_eq "count_at_mitigation recorded" "37" "$mitigated_count"

# === Test: mitigate overwrites previous mitigation ===
echo ""
echo "=== Test: mitigate overwrite ==="
"$MANAGE" mitigate test-failure-after-completion "Updated: now run tests twice"
mitigated2="$(jq -r '.["test-failure-after-completion"].mitigation' "$REGISTRY_FILE")"
assert_eq "mitigation updated" "Updated: now run tests twice" "$mitigated2"

# === Test: effectiveness command (no post-mitigation data) ===
echo ""
echo "=== Test: effectiveness no data ==="
eff_output="$("$MANAGE" effectiveness test-failure-after-completion)"
assert_contains "effectiveness shows pattern" "test-failure-after-completion" "$eff_output"

# === Test: effectiveness with post-mitigation feedback records ===
echo ""
echo "=== Test: effectiveness with data ==="

# Create feedback records: some before mitigation, some after
# The mitigation was set with count_at_mitigation=37
# Create 10 post-mitigation records: 3 have the pattern, 7 do not
for i in $(seq 1 7); do
  cat > "$TMPDIR/feedback/post-clean-$i.json" <<EOF
{
  "bead": "bd-post-$i",
  "template": "bug-fix",
  "agent": "claude",
  "outcome": "full_pass",
  "failure_patterns": []
}
EOF
done
for i in $(seq 1 3); do
  cat > "$TMPDIR/feedback/post-fail-$i.json" <<EOF
{
  "bead": "bd-postf-$i",
  "template": "bug-fix",
  "agent": "claude",
  "outcome": "partial_pass",
  "failure_patterns": ["test-failure-after-completion"]
}
EOF
done

# Update registry count to reflect post-mitigation occurrences (37 + 3 = 40)
jq '.["test-failure-after-completion"].count = 40' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

eff_output2="$("$MANAGE" effectiveness test-failure-after-completion)"
assert_contains "effectiveness shows post-mitigation rate" "30%" "$eff_output2"

# === Test: effectiveness for unmitigated pattern ===
echo ""
echo "=== Test: effectiveness unmitigated ==="
eff_unmit="$("$MANAGE" effectiveness scope-creep)"
assert_contains "unmitigated pattern noted" "no mitigation" "$eff_unmit"

# === Test: infra isolation in list ===
echo ""
echo "=== Test: infra pattern identification ==="
list_output2="$("$MANAGE" list)"
# Infra patterns should be marked/identified differently
assert_contains "infra patterns marked" "infra" "$list_output2"

# === Test: infra exclusion detail ===
echo ""
echo "=== Test: infra exclusion note ==="
detail_infra="$("$MANAGE" detail infra-tmux)"
assert_contains "infra detail notes exclusion" "excluded from template scoring" "$detail_infra"

# === Test: empty registry ===
echo ""
echo "=== Test: empty registry ==="
echo '{}' > "$REGISTRY_FILE"
empty_output="$("$MANAGE" list)"
assert_contains "empty registry message" "No patterns" "$empty_output"

# === Test: missing registry file ===
echo ""
echo "=== Test: missing registry ==="
rm -f "$REGISTRY_FILE"
missing_output="$("$MANAGE" list 2>&1 || true)"
assert_contains "missing registry message" "not found\|No pattern" "$missing_output"

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
