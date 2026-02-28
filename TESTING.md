# Testing — learning-loop

Evaluated against [TEST_RUBRIC.md](/home/polis/tools/TEST_RUBRIC.md).

---

## Rubric Scores

| Dimension                        | Before | After | Delta |
|----------------------------------|--------|-------|-------|
| 1. E2E Realism                   | 5      | 5     | —     |
| 2. Unit Test Behaviour Focus     | 3      | 4     | +1    |
| 3. Edge Case & Error Path        | 3      | 4     | +1    |
| 4. Test Isolation & Reliability  | 4      | 5     | +1    |
| 5. Regression Value              | 3      | 4     | +1    |
| **Total**                        | **18** | **22**| **+4**|
| **Grade**                        | B      | A     |       |

---

## Assessment Per Dimension

### 1. E2E Realism — 5/5
`e2e_test.go` is exemplary. It builds the real binary via `TestMain`, exercises every subcommand (init, ingest, query, analyze, status, patterns, insights, runs, report, version), tests the full ingest-analyze-query pipeline, and covers edge cases: unicode, null fields, extra JSON fields, special characters in IDs, duplicate ingestion, malformed input, rapid sequential ingestion of 20 runs, and a 50-run large-input stress test. No changes needed.

### 2. Unit Test Behaviour Focus — 4/5 (was 3)
Before: many `cmd/loop` tests were smoke tests checking only `err == nil` — they'd still pass after deleting core logic. After: tests now open the DB and verify actual state (runs stored with correct fields, patterns created, runs marked analyzed, insight text matches success-rate thresholds). `analyze_test.go` verifies all 9 pattern-to-insight-text mappings, confidence tiers, and tag inference contracts. Not a 5 because some commands write to `os.Stdout` directly (not the cobra buffer), limiting what unit tests can verify about formatted output.

### 3. Edge Case & Error Path Coverage — 4/5 (was 3)
Before: common error paths covered but missing important edge cases. After: `ingest_test.go` covers malformed JSON, empty input, empty object, broken `io.Reader`, partial fields, invalid outcome values. `db_test.go` covers nullable fields, empty path, `Conn()` method. `analyze_test.go` covers zero total runs in `generateInsightText`, low-frequency pattern skipping, and idempotent re-analysis. `cmd/loop/main_test.go` covers invalid DB path, nonexistent files, duplicate rejection, missing args. Not a 5 because DB corruption/recovery and truly concurrent writers are untested.

### 4. Test Isolation & Reliability — 5/5 (was 4)
Before: `TestOpenDB_DefaultPath` used `os.Chdir` which is not parallel-safe. After: that test was removed. Every test uses `t.TempDir()` for an independent database. No shared state, no `sleep()`, no flakiness, no timing dependencies. Tests are fast (~8s for `cmd/loop`, ~5s for ingest, ~3s for db). All tests are safe to run with `-parallel`.

### 5. Regression Value — 4/5 (was 3)
Before: many tests would not catch wrong output or broken insight generation. After: `TestPipeline_IngestAnalyzeProducesConsistentState` would catch breaks in the core workflow (verifies run counts, pattern frequencies, insight generation, query after pipeline). Success-rate threshold tests verify specific insight text ("Low success rate" / "Strong performance"). `TestGenerateInsightText_AllPatterns` would catch any pattern-text mapping change. JSON output contract test verifies required fields. Not a 5 because text-format output of `status`, `report`, `patterns`, and `insights` commands goes to `os.Stdout` and cannot be captured/asserted in unit tests (though E2E does catch this).

---

## What the Suite is MISSING

This is the most important section.

1. **DB corruption / recovery**: No test opens a corrupt SQLite file and verifies graceful error handling. If the DB file is truncated or contains garbage, we don't know what happens.

2. **Concurrent writers**: The E2E suite tests rapid sequential ingestion (20 runs), but no test exercises truly parallel writes to the same DB (e.g., two `ingest` commands racing). SQLite WAL mode should handle this, but it's untested.

3. **stdout output format verification in unit tests**: Commands like `status`, `report`, `patterns`, `insights`, `runs` write directly to `os.Stdout` rather than `cmd.OutOrStdout()`. This means unit tests cannot capture or assert on the text output. The E2E tests partially compensate, but a refactor of the commands to use `cmd.OutOrStdout()` would enable stronger unit-level assertions.

4. **Insight expiry**: Insights have an `expires_at` field and the schema supports it, but no test verifies that expired insights are excluded from queries. It's unclear whether the application even checks expiry.

5. **Large run payloads**: No test exercises a single run with hundreds of files_touched or dozens of tags. Edge behavior of JSON array fields at scale is untested.

6. **DB migration across versions**: No test opens a DB created with an older schema version and verifies that migrations run correctly. This matters for production use.

7. **Query relevance ranking**: `query` searches are tested for "does it return results" but not "does it return the most relevant results first". The matching logic in `internal/query` could silently degrade without failing tests.

---

## Coverage by Package

| Package           | Coverage |
|-------------------|----------|
| cmd/loop          | 78.1%    |
| internal/analyze  | 89.5%    |
| internal/db       | 84.9%    |
| internal/ingest   | 92.2%    |
| internal/query    | 86.4%    |
| internal/report   | 97.2%    |

---

## Changelog

### 2026-02-28 — Agent: apollo
- **Changed**: Rewrote `cmd/loop/main_test.go` to verify DB state instead of just checking `err == nil`
  - Tests now open the DB after commands and assert on stored runs, patterns, insight text
  - Added `openDB` helper to `testEnv` for direct DB state verification
  - Added pipeline integrity test (6 runs through ingest+analyze, verifies counts, patterns, insights)
  - Added success-rate threshold tests (low rate → "Low success rate", high rate → "Strong performance")
  - Added JSON output contract test (verifies required fields in serialized runs)
  - Added `TestPatternsCmd_DetectsExpectedPatterns` (verifies specific patterns from seed data)
  - Added `TestInsightsCmd_TagFilteringWorks` (covers `GetInsightsByTags` through CLI layer)
- **Removed**: `TestOpenDB_DefaultPath` (parallel-unsafe `os.Chdir`)
- **Removed**: Low-value flag registration tests already covered by E2E
- **Added**: `analyze_test.go` — consolidated `inferTags` tests into table-driven test
- **Added**: `analyze_test.go` — `TestGenerateInsightText_AllPatterns` covering all 9 pattern→text mappings
- **Added**: `analyze_test.go` — `TestGenerateInsightText_ZeroTotalRuns` edge case
- **Added**: `analyze_test.go` — confidence tier tests (high, medium) and low-frequency skip test
- **Added**: `analyze_test.go` — `TestGetInsightsByTags` (was 0% coverage)
- **Added**: `analyze_test.go` — `TestInsertInsight_WithExpiry` and `TestInsertInsight_Inactive`
- **Added**: `ingest_test.go` — error paths: malformed JSON, empty input, empty object, broken reader, partial fields, invalid outcome
- **Added**: `db_test.go` — `TestConn` and `TestOpenEmptyPath`
- Coverage delta: 63.3% → ~87% (meaningful: 30+ new tests covering real behaviour, not just import/compile checks)
