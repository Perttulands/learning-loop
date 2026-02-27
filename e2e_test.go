package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var loopBinary string

func TestMain(m *testing.M) {
	// Build the binary once for all e2e tests
	dir, err := os.MkdirTemp("", "loop-e2e-build-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "create temp dir: %v\n", err)
		os.Exit(1)
	}

	loopBinary = filepath.Join(dir, "loop")
	cmd := exec.Command("go", "build", "-o", loopBinary, "./cmd/loop/")
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build: %v\n%s\n", err, out)
		os.Exit(1)
	}

	code := m.Run()
	os.Remove(loopBinary)
	os.Remove(dir)
	os.Exit(code)
}

func runLoop(t *testing.T, dir string, args ...string) (string, error) {
	t.Helper()
	dbPath := filepath.Join(dir, ".learning-loop", "loop.db")
	fullArgs := append([]string{"--db", dbPath}, args...)
	cmd := exec.Command(loopBinary, fullArgs...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func runLoopStdin(t *testing.T, dir string, stdin string, args ...string) (string, error) {
	t.Helper()
	dbPath := filepath.Join(dir, ".learning-loop", "loop.db")
	fullArgs := append([]string{"--db", dbPath}, args...)
	cmd := exec.Command(loopBinary, fullArgs...)
	cmd.Dir = dir
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// ─── INIT ────────────────────────────────────────────────────────────────────

func TestE2E_Init(t *testing.T) {
	dir := t.TempDir()
	out, err := runLoop(t, dir, "init")
	if err != nil {
		t.Fatalf("init failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "initialized") {
		t.Errorf("init output missing 'initialized': %s", out)
	}

	// DB file should exist
	dbPath := filepath.Join(dir, ".learning-loop", "loop.db")
	if _, err := os.Stat(dbPath); err != nil {
		t.Errorf("db file not created: %v", err)
	}
}

func TestE2E_InitIdempotent(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")
	out, err := runLoop(t, dir, "init")
	if err != nil {
		t.Fatalf("second init failed: %v\n%s", err, out)
	}
}

// ─── INGEST ──────────────────────────────────────────────────────────────────

func TestE2E_IngestFromStdin(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"e2e-1","task":"Fix auth","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true}`
	out, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("ingest failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Ingested") {
		t.Errorf("ingest output missing 'Ingested': %s", out)
	}
	if !strings.Contains(out, "e2e-1") {
		t.Errorf("ingest output missing run ID: %s", out)
	}
}

func TestE2E_IngestFromFile(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	runFile := filepath.Join(dir, "run.json")
	os.WriteFile(runFile, []byte(`{"id":"file-1","task":"Fix bug","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","tests_passed":false}`), 0o644)

	out, err := runLoop(t, dir, "ingest", runFile)
	if err != nil {
		t.Fatalf("ingest file failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "file-1") {
		t.Errorf("ingest output missing run ID: %s", out)
	}
}

func TestE2E_IngestDuplicate(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"dup-1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`
	runLoopStdin(t, dir, input, "ingest", "-")
	_, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err == nil {
		t.Fatal("duplicate ingest should fail")
	}
}

func TestE2E_IngestMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	_, err := runLoopStdin(t, dir, "not json at all", "ingest", "-")
	if err == nil {
		t.Fatal("malformed JSON should fail")
	}
}

func TestE2E_IngestEmptyInput(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	_, err := runLoopStdin(t, dir, "", "ingest", "-")
	if err == nil {
		t.Fatal("empty input should fail")
	}
}

func TestE2E_IngestMissingRequiredFields(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	tests := []struct {
		name  string
		input string
	}{
		{"no id", `{"task":"t","outcome":"success"}`},
		{"no task", `{"id":"x","outcome":"success"}`},
		{"no outcome", `{"id":"x","task":"t"}`},
		{"bad outcome", `{"id":"x","task":"t","outcome":"maybe"}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := runLoopStdin(t, dir, tt.input, "ingest", "-")
			if err == nil {
				t.Fatalf("%s: expected error", tt.name)
			}
		})
	}
}

func TestE2E_IngestPatternDetection(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"pat-1","task":"Fix bug","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","tests_passed":false}`
	out, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("ingest failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "tests-failed") {
		t.Errorf("should detect tests-failed pattern: %s", out)
	}
}

func TestE2E_IngestNonexistentFile(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	_, err := runLoop(t, dir, "ingest", "/nonexistent/file.json")
	if err == nil {
		t.Fatal("nonexistent file should fail")
	}
}

// ─── QUERY ───────────────────────────────────────────────────────────────────

func TestE2E_QueryEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "query", "anything")
	if err != nil {
		t.Fatalf("query failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No relevant learnings") {
		t.Errorf("empty query should show helpful message: %s", out)
	}
}

func TestE2E_QueryWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "query", "fix auth bug")
	if err != nil {
		t.Fatalf("query failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "LEARNINGS") {
		t.Errorf("query should show LEARNINGS: %s", out)
	}
}

func TestE2E_QueryJSON(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "query", "fix auth bug", "--json")
	if err != nil {
		t.Fatalf("query json failed: %v\n%s", err, out)
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
	if _, ok := result["query"]; !ok {
		t.Error("JSON missing 'query' field")
	}
	if _, ok := result["matched_runs"]; !ok {
		t.Error("JSON missing 'matched_runs' field")
	}
}

func TestE2E_QueryInject(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "query", "fix auth bug", "--inject")
	if err != nil {
		t.Fatalf("query inject failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "## Learnings for:") {
		t.Errorf("inject output should start with markdown header: %s", out)
	}
}

// ─── ANALYZE ─────────────────────────────────────────────────────────────────

func TestE2E_AnalyzeEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("analyze failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No new runs") {
		t.Errorf("empty analyze should say no new runs: %s", out)
	}
}

func TestE2E_AnalyzeWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("analyze failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Analyzed") {
		t.Errorf("analyze should say Analyzed: %s", out)
	}
}

func TestE2E_AnalyzeJSON(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "analyze", "--json")
	if err != nil {
		t.Fatalf("analyze json failed: %v\n%s", err, out)
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
}

func TestE2E_AnalyzeIdempotent(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	runLoop(t, dir, "analyze")
	out, err := runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("second analyze failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No new runs") {
		t.Errorf("second analyze should say no new runs: %s", out)
	}
}

// ─── STATUS ──────────────────────────────────────────────────────────────────

func TestE2E_StatusEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "status")
	if err != nil {
		t.Fatalf("status failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No data yet") {
		t.Errorf("empty status should show onboarding: %s", out)
	}
}

func TestE2E_StatusWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)
	runLoop(t, dir, "analyze")

	out, err := runLoop(t, dir, "status")
	if err != nil {
		t.Fatalf("status failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Runs:") {
		t.Errorf("status should show runs: %s", out)
	}
}

// ─── PATTERNS ────────────────────────────────────────────────────────────────

func TestE2E_PatternsEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "patterns")
	if err != nil {
		t.Fatalf("patterns failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No patterns") {
		t.Errorf("empty patterns should show message: %s", out)
	}
}

func TestE2E_PatternsWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "patterns")
	if err != nil {
		t.Fatalf("patterns failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "tests-failed") {
		t.Errorf("patterns should show tests-failed: %s", out)
	}
}

// ─── INSIGHTS ────────────────────────────────────────────────────────────────

func TestE2E_InsightsEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "insights")
	if err != nil {
		t.Fatalf("insights failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No insights") {
		t.Errorf("empty insights should show message: %s", out)
	}
}

func TestE2E_InsightsTagsFilter(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	// Ingest runs that trigger "tests-failed" pattern (category="code") >= 3 times
	// so that analyze generates an insight with tags ["code-quality","testing"]
	for i := 0; i < 4; i++ {
		input := fmt.Sprintf(`{"id":"tag-%d","task":"Fix bug %d","outcome":"failure","timestamp":"2026-02-22T%02d:00:00Z","tests_passed":false,"tags":["bugfix"]}`, i, i, 10+i)
		_, err := runLoopStdin(t, dir, input, "ingest", "-")
		if err != nil {
			t.Fatalf("ingest tag-%d: %v", i, err)
		}
	}
	// Also ingest some successes so overall stats work
	for i := 0; i < 3; i++ {
		input := fmt.Sprintf(`{"id":"tag-ok-%d","task":"Feature %d","outcome":"success","timestamp":"2026-02-22T%02d:00:00Z","tests_passed":true,"tags":["feature"]}`, i, i, 14+i)
		_, err := runLoopStdin(t, dir, input, "ingest", "-")
		if err != nil {
			t.Fatalf("ingest tag-ok-%d: %v", i, err)
		}
	}

	// Run analyze to generate insights from patterns
	out, err := runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v\n%s", err, out)
	}

	// First: get all insights (no tag filter) as JSON
	allOut, err := runLoop(t, dir, "insights", "--json")
	if err != nil {
		t.Fatalf("insights --json: %v\n%s", err, allOut)
	}
	var allInsights []map[string]interface{}
	if err := json.Unmarshal([]byte(allOut), &allInsights); err != nil {
		t.Fatalf("parse all insights: %v\n%s", err, allOut)
	}
	if len(allInsights) == 0 {
		t.Fatal("expected at least one insight after analyze")
	}

	// Filter by "testing" tag — should find the tests-failed insight
	filteredOut, err := runLoop(t, dir, "insights", "--tags", "testing", "--json")
	if err != nil {
		t.Fatalf("insights --tags testing --json: %v\n%s", err, filteredOut)
	}
	var filteredInsights []map[string]interface{}
	if err := json.Unmarshal([]byte(filteredOut), &filteredInsights); err != nil {
		t.Fatalf("parse filtered insights: %v\n%s", err, filteredOut)
	}
	if len(filteredInsights) == 0 {
		t.Fatal("expected insights with 'testing' tag")
	}
	// Verify all filtered insights have the "testing" tag
	for _, ins := range filteredInsights {
		tags, ok := ins["tags"].([]interface{})
		if !ok {
			continue
		}
		found := false
		for _, tag := range tags {
			if tag.(string) == "testing" {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("filtered insight should have 'testing' tag, got tags: %v", tags)
		}
	}

	// Filter by a tag that no insight has — should return empty
	emptyOut, err := runLoop(t, dir, "insights", "--tags", "nonexistent-tag-xyz", "--json")
	if err != nil {
		t.Fatalf("insights --tags nonexistent: %v\n%s", err, emptyOut)
	}
	// JSON output for empty list should be null or []
	trimmed := strings.TrimSpace(emptyOut)
	if trimmed != "null" && trimmed != "[]" {
		var emptyInsights []map[string]interface{}
		if err := json.Unmarshal([]byte(emptyOut), &emptyInsights); err != nil {
			t.Fatalf("parse empty insights: %v\n%s", err, emptyOut)
		}
		if len(emptyInsights) != 0 {
			t.Errorf("nonexistent tag should return no insights, got %d", len(emptyInsights))
		}
	}

	// Filtered count should be <= total count
	if len(filteredInsights) > len(allInsights) {
		t.Errorf("filtered (%d) should be <= total (%d)", len(filteredInsights), len(allInsights))
	}
}

// ─── RUNS ────────────────────────────────────────────────────────────────────

func TestE2E_RunsEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "runs")
	if err != nil {
		t.Fatalf("runs failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No runs") {
		t.Errorf("empty runs should show message: %s", out)
	}
}

func TestE2E_RunsWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "runs")
	if err != nil {
		t.Fatalf("runs failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "e2e-") {
		t.Errorf("runs should show seeded run IDs: %s", out)
	}
}

func TestE2E_RunsFilterOutcome(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "runs", "--outcome", "failure")
	if err != nil {
		t.Fatalf("runs filtered failed: %v\n%s", err, out)
	}
	if strings.Contains(out, "success") {
		t.Errorf("filtered runs should not show success: %s", out)
	}
}

func TestE2E_RunsJSON(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "runs", "--json")
	if err != nil {
		t.Fatalf("runs json failed: %v\n%s", err, out)
	}

	var runs []map[string]interface{}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
	if len(runs) == 0 {
		t.Error("expected runs in JSON output")
	}
}

func TestE2E_RunsLast(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)

	out, err := runLoop(t, dir, "runs", "--last", "2", "--json")
	if err != nil {
		t.Fatalf("runs --last failed: %v\n%s", err, out)
	}

	var runs []map[string]interface{}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
	if len(runs) != 2 {
		t.Errorf("--last 2 should return 2 runs, got %d", len(runs))
	}
}

// ─── REPORT ──────────────────────────────────────────────────────────────────

func TestE2E_ReportEmpty(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	out, err := runLoop(t, dir, "report")
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No data yet") {
		t.Errorf("empty report should show onboarding: %s", out)
	}
}

func TestE2E_ReportWithData(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)
	runLoop(t, dir, "analyze")

	out, err := runLoop(t, dir, "report")
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Learning Loop Report") {
		t.Errorf("report should show header: %s", out)
	}
	if !strings.Contains(out, "Runs:") {
		t.Errorf("report should show runs stat: %s", out)
	}
	if !strings.Contains(out, "Rate:") {
		t.Errorf("report should show success rate: %s", out)
	}
}

func TestE2E_ReportJSON(t *testing.T) {
	dir := t.TempDir()
	seedE2E(t, dir)
	runLoop(t, dir, "analyze")

	out, err := runLoop(t, dir, "report", "--json")
	if err != nil {
		t.Fatalf("report json failed: %v\n%s", err, out)
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, out)
	}
	if _, ok := result["total_runs"]; !ok {
		t.Error("JSON missing 'total_runs' field")
	}
	if _, ok := result["success_rate"]; !ok {
		t.Error("JSON missing 'success_rate' field")
	}
	if _, ok := result["patterns"]; !ok {
		t.Error("JSON missing 'patterns' field")
	}
	if _, ok := result["insights"]; !ok {
		t.Error("JSON missing 'insights' field")
	}
}

// ─── VERSION ─────────────────────────────────────────────────────────────────

func TestE2E_Version(t *testing.T) {
	dir := t.TempDir()
	out, err := runLoop(t, dir, "version")
	if err != nil {
		t.Fatalf("version failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "loop") {
		t.Errorf("version output missing 'loop': %s", out)
	}
}

// ─── FULL PIPELINE ───────────────────────────────────────────────────────────

func TestE2E_FullPipeline(t *testing.T) {
	dir := t.TempDir()

	// 1. Init
	out, err := runLoop(t, dir, "init")
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}

	// 2. Ingest 6 diverse runs
	runs := []string{
		`{"id":"fp-1","task":"Fix authentication bug","outcome":"success","timestamp":"2026-02-22T10:00:00Z","duration_seconds":300,"tests_passed":true,"lint_passed":true,"tags":["auth","bug"],"files_touched":["auth.go","auth_test.go"]}`,
		`{"id":"fp-2","task":"Fix auth middleware","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","duration_seconds":120,"tests_passed":false,"tags":["auth"],"files_touched":["middleware.go"]}`,
		`{"id":"fp-3","task":"Add user registration","outcome":"success","timestamp":"2026-02-22T12:00:00Z","duration_seconds":450,"tests_passed":true,"tags":["user"],"files_touched":["user.go","user_test.go"]}`,
		`{"id":"fp-4","task":"Fix database pooling","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","duration_seconds":30,"tags":["database"],"files_touched":["db.go"]}`,
		`{"id":"fp-5","task":"Refactor auth tokens","outcome":"success","timestamp":"2026-02-22T14:00:00Z","duration_seconds":200,"tests_passed":true,"tags":["auth"],"files_touched":["auth.go","token.go","token_test.go"]}`,
		`{"id":"fp-6","task":"Fix rate limiting","outcome":"failure","timestamp":"2026-02-22T15:00:00Z","tests_passed":false,"lint_passed":false,"tags":["auth"],"files_touched":["ratelimit.go"]}`,
	}

	for _, r := range runs {
		out, err = runLoopStdin(t, dir, r, "ingest", "-")
		if err != nil {
			t.Fatalf("ingest: %v\n%s", err, out)
		}
	}

	// 3. Analyze
	out, err = runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v\n%s", err, out)
	}
	if !strings.Contains(out, "6 new runs") {
		t.Errorf("analyze should process 6 runs: %s", out)
	}

	// 4. Query
	out, err = runLoop(t, dir, "query", "fix auth bug")
	if err != nil {
		t.Fatalf("query: %v\n%s", err, out)
	}
	if !strings.Contains(out, "LEARNINGS") {
		t.Errorf("query should show LEARNINGS: %s", out)
	}

	// 5. Status
	out, err = runLoop(t, dir, "status")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	if !strings.Contains(out, "6 total") {
		t.Errorf("status should show 6 total: %s", out)
	}

	// 6. Patterns
	out, err = runLoop(t, dir, "patterns")
	if err != nil {
		t.Fatalf("patterns: %v\n%s", err, out)
	}
	if !strings.Contains(out, "tests-failed") {
		t.Errorf("patterns should show tests-failed: %s", out)
	}

	// 7. Insights
	out, err = runLoop(t, dir, "insights")
	if err != nil {
		t.Fatalf("insights: %v\n%s", err, out)
	}

	// 8. Runs
	out, err = runLoop(t, dir, "runs")
	if err != nil {
		t.Fatalf("runs: %v\n%s", err, out)
	}
	if !strings.Contains(out, "fp-1") {
		t.Errorf("runs should show fp-1: %s", out)
	}
}

// ─── CONCURRENT ACCESS ──────────────────────────────────────────────────────

func TestE2E_RapidSequentialIngestion(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	// Rapid sequential ingestion — the real-world pattern
	for i := 0; i < 20; i++ {
		input := fmt.Sprintf(`{"id":"rapid-%d","task":"task %d","outcome":"success","timestamp":"2026-01-01T%02d:00:00Z"}`, i, i, i%24)
		_, err := runLoopStdin(t, dir, input, "ingest", "-")
		if err != nil {
			t.Fatalf("rapid ingest %d: %v", i, err)
		}
	}

	// Verify all 20 runs are there
	out, err := runLoop(t, dir, "runs", "--json")
	if err != nil {
		t.Fatalf("runs: %v\n%s", err, out)
	}

	var runs []map[string]interface{}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if len(runs) != 20 {
		t.Errorf("expected 20 runs, got %d", len(runs))
	}
}

// ─── LARGE INPUT ─────────────────────────────────────────────────────────────

func TestE2E_LargeInput(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	// Ingest 50 runs
	for i := 0; i < 50; i++ {
		outcome := "success"
		if i%3 == 0 {
			outcome = "failure"
		}
		input := fmt.Sprintf(`{"id":"large-%d","task":"Task number %d with some description","outcome":"%s","timestamp":"2026-02-01T%02d:%02d:00Z","duration_seconds":%d,"tags":["tag%d","tag%d"]}`,
			i, i, outcome, i%24, i%60, 60+i*10, i%5, i%3)
		_, err := runLoopStdin(t, dir, input, "ingest", "-")
		if err != nil {
			t.Fatalf("ingest %d: %v", i, err)
		}
	}

	// Analyze
	out, err := runLoop(t, dir, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v\n%s", err, out)
	}
	if !strings.Contains(out, "50 new runs") {
		t.Errorf("analyze should process 50 runs: %s", out)
	}

	// Query should still work fast
	out, err = runLoop(t, dir, "query", "task number", "--json")
	if err != nil {
		t.Fatalf("query: %v\n%s", err, out)
	}

	var result map[string]interface{}
	json.Unmarshal([]byte(out), &result)
	total := result["total_runs"].(float64)
	if total != 50 {
		t.Errorf("total_runs = %v, want 50", total)
	}
}

// ─── EDGE CASES ──────────────────────────────────────────────────────────────

func TestE2E_UnicodeInTask(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"uni-1","task":"修复认证错误 — fix auth 🐛","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`
	out, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("unicode ingest failed: %v\n%s", err, out)
	}
}

func TestE2E_LongTaskDescription(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	longTask := strings.Repeat("Fix the very long authentication bug that spans multiple lines and includes lots of detail about what went wrong ", 10)
	input := fmt.Sprintf(`{"id":"long-1","task":"%s","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`, longTask)
	out, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("long task ingest failed: %v\n%s", err, out)
	}
}

func TestE2E_EmptyTags(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"empty-tags","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tags":[]}`
	_, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("empty tags ingest failed: %v", err)
	}
}

func TestE2E_NullFields(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"null-1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":null,"lint_passed":null,"error_message":null,"duration_seconds":null}`
	_, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("null fields ingest failed: %v", err)
	}
}

func TestE2E_ExtraFields(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"extra-1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","unknown_field":"value","nested":{"key":"val"}}`
	_, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("extra fields ingest failed: %v", err)
	}
}

func TestE2E_SpecialCharsInID(t *testing.T) {
	dir := t.TempDir()
	runLoop(t, dir, "init")

	input := `{"id":"run/with-special_chars.v2","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`
	_, err := runLoopStdin(t, dir, input, "ingest", "-")
	if err != nil {
		t.Fatalf("special chars ID ingest failed: %v", err)
	}
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

func seedE2E(t *testing.T, dir string) {
	t.Helper()
	runLoop(t, dir, "init")

	runs := []string{
		`{"id":"e2e-1","task":"Fix auth bug","outcome":"success","timestamp":"2026-02-22T10:00:00Z","duration_seconds":300,"tests_passed":true,"tags":["auth","bug"],"files_touched":["auth.go","auth_test.go"]}`,
		`{"id":"e2e-2","task":"Fix auth middleware","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","duration_seconds":120,"tests_passed":false,"tags":["auth"],"files_touched":["middleware.go"]}`,
		`{"id":"e2e-3","task":"Add user feature","outcome":"success","timestamp":"2026-02-22T12:00:00Z","duration_seconds":450,"tests_passed":true,"tags":["user"],"files_touched":["user.go","user_test.go"]}`,
		`{"id":"e2e-4","task":"Fix db pool","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","duration_seconds":30,"tags":["database"],"files_touched":["db.go"]}`,
		`{"id":"e2e-5","task":"Refactor auth","outcome":"success","timestamp":"2026-02-22T14:00:00Z","duration_seconds":200,"tests_passed":true,"tags":["auth"],"files_touched":["auth.go","token_test.go"]}`,
	}

	for _, r := range runs {
		out, err := runLoopStdin(t, dir, r, "ingest", "-")
		if err != nil {
			t.Fatalf("seed: %v\n%s", err, out)
		}
	}
}
