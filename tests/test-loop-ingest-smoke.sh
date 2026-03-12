#!/usr/bin/env bash
# test-loop-ingest-smoke.sh - Smoke test the bundled loop binary ingest path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOOP_BIN="$PROJECT_DIR/loop"
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
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

DB_PATH="$TMPDIR/loop.db"
FILE_RUN="$TMPDIR/work-feed-file.json"

cat > "$FILE_RUN" <<'EOF'
{
  "id": "phase1-file",
  "task": "Fix login bug",
  "outcome": "success",
  "timestamp": "2026-03-12T10:00:00Z",
  "tests_passed": true,
  "lint_passed": true,
  "tools_used": ["read", "edit", "bash"],
  "files_touched": ["src/auth.sh", "tests/auth.sh"],
  "tags": ["auth", "bug-fix"],
  "agent": "codex",
  "model": "gpt-5.3-codex",
  "metadata": {
    "source": "phase1-smoke"
  }
}
EOF

echo "=== Binary availability ==="
assert_eq "loop binary exists" "true" "$([ -f "$LOOP_BIN" ] && echo true || echo false)"
assert_eq "loop binary is executable" "true" "$([ -x "$LOOP_BIN" ] && echo true || echo false)"

echo "=== Init database ==="
"$LOOP_BIN" --db "$DB_PATH" init >/dev/null
assert_eq "database file created" "true" "$([ -f "$DB_PATH" ] && echo true || echo false)"

echo "=== Ingest from file ==="
file_output="$("$LOOP_BIN" --db "$DB_PATH" ingest "$FILE_RUN")"
assert_contains "file ingest reports run id" "Ingested phase1-file [success]" "$file_output"

echo "=== Ingest from stdin ==="
stdin_output="$(
  printf '%s\n' \
    '{"id":"phase1-stdin","task":"Stabilize smoke ingestion","outcome":"partial","timestamp":"2026-03-12T10:05:00Z","tests_passed":false,"lint_passed":true,"metadata":{"source":"phase1-smoke"}}' \
  | "$LOOP_BIN" --db "$DB_PATH" ingest -
)"
assert_contains "stdin ingest reports run id" "Ingested phase1-stdin [partial]" "$stdin_output"
assert_contains "stdin ingest surfaces detected pattern" "Patterns: tests-failed" "$stdin_output"

echo "=== Runs output ==="
runs_json="$("$LOOP_BIN" --db "$DB_PATH" runs --json)"
assert_eq "two runs ingested" "2" "$(echo "$runs_json" | jq 'length')"
assert_eq "file record kept success outcome" "success" \
  "$(echo "$runs_json" | jq -r 'map(select(.id == "phase1-file"))[0].outcome')"
assert_eq "stdin record kept partial outcome" "partial" \
  "$(echo "$runs_json" | jq -r 'map(select(.id == "phase1-stdin"))[0].outcome')"
assert_eq "stdin record kept tests result" "false" \
  "$(echo "$runs_json" | jq -r 'map(select(.id == "phase1-stdin"))[0].tests_passed')"
assert_eq "file record preserved metadata source" "phase1-smoke" \
  "$(echo "$runs_json" | jq -r 'map(select(.id == "phase1-file"))[0].metadata.source')"

echo "=== Patterns output ==="
patterns_json="$("$LOOP_BIN" --db "$DB_PATH" patterns --json)"
assert_eq "tests-failed pattern recorded" "pat-tests-failed" \
  "$(echo "$patterns_json" | jq -r 'map(select(.name == "tests-failed"))[0].id')"
assert_eq "tests-failed frequency recorded" "1" \
  "$(echo "$patterns_json" | jq -r 'map(select(.name == "tests-failed"))[0].frequency')"

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
