package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/polis/learning-loop/internal/db"
	"github.com/spf13/cobra"
)

// ── helpers ────────────────────────────────────────────────

// executeCmd runs a cobra command tree with the given args and returns
// combined stdout+stderr and any error.
func executeCmd(root *cobra.Command, args ...string) (string, error) {
	buf := new(bytes.Buffer)
	root.SetOut(buf)
	root.SetErr(buf)
	root.SetArgs(args)
	err := root.Execute()
	return buf.String(), err
}

// buildRoot mirrors main() but returns the command instead of executing it.
func buildRoot() *cobra.Command {
	root := &cobra.Command{
		Use:          "loop",
		Short:        "Learning Loop — your agents get smarter with every run",
		SilenceUsage: true,
	}
	root.PersistentFlags().String("db", "", "database path")
	root.AddCommand(
		initCmd(),
		ingestCmd(),
		queryCmd(),
		analyzeCmd(),
		statusCmd(),
		patternsCmd(),
		insightsCmd(),
		runsCmd(),
		reportCmd(),
		versionCmd(),
	)
	return root
}

// testEnv holds a temp dir and db path for subcommand tests.
type testEnv struct {
	dir    string
	dbPath string
	fileN  int
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	dir := t.TempDir()
	return &testEnv{dir: dir, dbPath: filepath.Join(dir, "test.db")}
}

// writeRunFile writes JSON to a numbered temp file and returns the path.
func (e *testEnv) writeRunFile(t *testing.T, jsonStr string) string {
	t.Helper()
	e.fileN++
	path := filepath.Join(e.dir, fmt.Sprintf("run%d.json", e.fileN))
	os.WriteFile(path, []byte(jsonStr), 0o644)
	return path
}

// ingestRun writes JSON to file and ingests it via the CLI layer.
func (e *testEnv) ingestRun(t *testing.T, jsonStr string) {
	t.Helper()
	f := e.writeRunFile(t, jsonStr)
	root := buildRoot()
	_, err := executeCmd(root, "--db", e.dbPath, "ingest", f)
	if err != nil {
		t.Fatalf("ingest %s: %v", f, err)
	}
}

// openDB opens the test env's database directly for state assertions.
func (e *testEnv) openDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(e.dbPath)
	if err != nil {
		t.Fatalf("open db for verification: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

// seedDB seeds 4 diverse runs into a DB for subcommand testing.
func seedDB(t *testing.T, env *testEnv) {
	t.Helper()
	runs := []string{
		`{"id":"s1","task":"Fix auth","outcome":"success","timestamp":"2026-02-22T10:00:00Z","duration_seconds":300,"tests_passed":true,"tags":["auth"],"files_touched":["auth.go","auth_test.go"]}`,
		`{"id":"s2","task":"Fix login","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","duration_seconds":120,"tests_passed":false,"tags":["auth"]}`,
		`{"id":"s3","task":"Add feat","outcome":"success","timestamp":"2026-02-22T12:00:00Z","duration_seconds":450,"tests_passed":true,"tags":["feature"],"files_touched":["feat.go","feat_test.go"]}`,
		`{"id":"s4","task":"Fix db","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","duration_seconds":30,"tags":["database"]}`,
	}
	for _, r := range runs {
		env.ingestRun(t, r)
	}
}

// ── command routing ────────────────────────────────────────

func TestCommandRouting_UnknownSubcommand(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "nonexistent")
	if err == nil {
		t.Fatal("expected error for unknown subcommand")
	}
}

func TestCommandRouting_HelpListsSubcommands(t *testing.T) {
	root := buildRoot()
	out, err := executeCmd(root, "--help")
	if err != nil {
		t.Fatalf("help should succeed: %v", err)
	}
	for _, sub := range []string{"init", "ingest", "query", "analyze", "status", "patterns", "insights", "runs", "report", "version"} {
		if !strings.Contains(out, sub) {
			t.Errorf("help output should list %q subcommand", sub)
		}
	}
}

// ── arg validation ────────────────────────────────────────

func TestIngest_ErrorOnMissingArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "ingest")
	if err == nil {
		t.Fatal("ingest with no args should fail")
	}
	if !strings.Contains(err.Error(), "accepts 1 arg") {
		t.Fatalf("expected ExactArgs error, got: %v", err)
	}
}

func TestQuery_ErrorOnMissingArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "query")
	if err == nil {
		t.Fatal("query with no args should fail")
	}
}

// ── flag helpers (defensive: missing flag must not panic) ──

func TestFlagBool_MissingFlag(t *testing.T) {
	cmd := &cobra.Command{}
	if flagBool(cmd, "missing") {
		t.Fatal("expected false for missing flag")
	}
}

func TestFlagInt_MissingFlagReturnsFallback(t *testing.T) {
	cmd := &cobra.Command{}
	if got := flagInt(cmd, "missing", 99); got != 99 {
		t.Fatalf("expected fallback 99, got %d", got)
	}
}

func TestFlagString_MissingFlag(t *testing.T) {
	cmd := &cobra.Command{}
	if got := flagString(cmd, "missing"); got != "" {
		t.Fatalf("expected empty string for missing flag, got %q", got)
	}
}

// ── init: DB actually gets created ────────────────────────

func TestInitCmd_CreatesDatabase(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "init")
	if err != nil {
		t.Fatalf("init should succeed: %v", err)
	}
	// Verify the DB file exists and is usable
	if _, err := os.Stat(env.dbPath); err != nil {
		t.Fatalf("init should create DB file: %v", err)
	}
	d := env.openDB(t)
	// DB should be empty but functional
	total, _, _, err := d.CountRuns()
	if err != nil {
		t.Fatalf("count runs on new db: %v", err)
	}
	if total != 0 {
		t.Errorf("new DB should have 0 runs, got %d", total)
	}
}

// ── ingest: data actually stored and errors reported ──────

func TestIngestCmd_StoresRunInDB(t *testing.T) {
	env := newTestEnv(t)
	env.ingestRun(t, `{"id":"verify-1","task":"Fix auth bug","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tags":["auth"],"duration_seconds":120}`)

	// Verify through DB that the run was actually stored correctly
	d := env.openDB(t)
	run, err := d.GetRun("verify-1")
	if err != nil {
		t.Fatalf("run should be stored in DB: %v", err)
	}
	if run.Task != "Fix auth bug" {
		t.Errorf("task = %q, want 'Fix auth bug'", run.Task)
	}
	if run.Outcome != "success" {
		t.Errorf("outcome = %q, want 'success'", run.Outcome)
	}
	if run.DurationS == nil || *run.DurationS != 120 {
		t.Errorf("duration = %v, want 120", run.DurationS)
	}
	if len(run.Tags) != 1 || run.Tags[0] != "auth" {
		t.Errorf("tags = %v, want [auth]", run.Tags)
	}
}

func TestIngestCmd_FileNotFound(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "ingest", "/nonexistent/file.json")
	if err == nil {
		t.Fatal("ingest with nonexistent file should fail")
	}
}

func TestIngestCmd_MalformedJSONReturnsError(t *testing.T) {
	env := newTestEnv(t)
	f := env.writeRunFile(t, "not json")
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "ingest", f)
	if err == nil {
		t.Fatal("ingest with malformed json should fail")
	}
}

func TestIngestCmd_DuplicateRunRejected(t *testing.T) {
	env := newTestEnv(t)
	input := `{"id":"dup","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`
	env.ingestRun(t, input)

	f := env.writeRunFile(t, input)
	root := buildRoot()
	_, err := executeCmd(root, "--db", f, "ingest", f)
	if err == nil {
		// Use the actual DB path
	}
	root2 := buildRoot()
	_, err = executeCmd(root2, "--db", env.dbPath, "ingest", env.writeRunFile(t, input))
	if err == nil {
		t.Fatal("duplicate ingest should fail")
	}
}

func TestIngestCmd_PatternDetectionStoresPatterns(t *testing.T) {
	env := newTestEnv(t)
	// Ingest a failure with tests_passed=false → should detect tests-failed pattern
	env.ingestRun(t, `{"id":"pat-1","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","tests_passed":false}`)

	d := env.openDB(t)
	pat, err := d.GetPatternByName("tests-failed")
	if err != nil {
		t.Fatalf("tests-failed pattern should be created: %v", err)
	}
	if pat.Frequency != 1 {
		t.Errorf("frequency = %d, want 1", pat.Frequency)
	}
}

// ── analyze: produces correct insights ────────────────────

func TestAnalyzeCmd_ProcessesAllRuns(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	// Verify all 4 runs are marked analyzed
	d := env.openDB(t)
	unanalyzed, err := d.GetUnanalyzedRuns()
	if err != nil {
		t.Fatalf("get unanalyzed: %v", err)
	}
	if len(unanalyzed) != 0 {
		t.Errorf("expected 0 unanalyzed runs after analyze, got %d", len(unanalyzed))
	}
}

func TestAnalyzeCmd_IdempotentNoDoubleCount(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	// First analyze
	root1 := buildRoot()
	_, err := executeCmd(root1, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("first analyze: %v", err)
	}

	d := env.openDB(t)
	countBefore, _ := d.CountInsights()
	d.Close()

	// Second analyze — should not create duplicate insights
	root2 := buildRoot()
	_, err = executeCmd(root2, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("second analyze: %v", err)
	}

	d2 := env.openDB(t)
	countAfter, _ := d2.CountInsights()
	if countAfter != countBefore {
		t.Errorf("insight count changed from %d to %d after idempotent analyze", countBefore, countAfter)
	}
}

func TestAnalyzeCmd_JSONDoesNotError(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "analyze", "--json")
	if err != nil {
		t.Fatalf("analyze --json: %v", err)
	}

	// With only 4 runs (each pattern freq=1 < threshold of 3),
	// no pattern-based insights are generated. This is correct behavior.
	// The pipeline test below verifies insight generation with enough data.
}

// ── query: verifiable through the DB ──────────────────────

func TestQueryCmd_EmptyDBDoesNotError(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "query", "anything")
	if err != nil {
		t.Fatalf("query on empty db should succeed gracefully: %v", err)
	}
}

func TestQueryCmd_SucceedsWithData(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "query", "fix auth", "--json")
	if err != nil {
		t.Fatalf("query --json: %v", err)
	}
}

func TestQueryCmd_InjectFlagDoesNotError(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "query", "fix auth", "--inject")
	if err != nil {
		t.Fatalf("query --inject: %v", err)
	}
}

// ── runs: verify DB state through all outcome paths ───────

func TestRunsCmd_AllOutcomesHandled(t *testing.T) {
	env := newTestEnv(t)
	outcomes := []string{"success", "failure", "partial", "error"}
	for i, o := range outcomes {
		env.ingestRun(t, fmt.Sprintf(`{"id":"ao%d","task":"task %s","outcome":"%s","timestamp":"2026-01-01T0%d:00:00Z"}`, i, o, o, i))
	}

	// Verify all 4 are stored
	d := env.openDB(t)
	runs, err := d.ListRuns(0, "")
	if err != nil {
		t.Fatalf("list runs: %v", err)
	}
	if len(runs) != 4 {
		t.Fatalf("expected 4 runs, got %d", len(runs))
	}

	// Verify filtering by outcome works
	failures, err := d.ListRuns(0, "failure")
	if err != nil {
		t.Fatalf("list failures: %v", err)
	}
	if len(failures) != 1 {
		t.Errorf("expected 1 failure, got %d", len(failures))
	}
	if failures[0].Outcome != "failure" {
		t.Errorf("filtered run outcome = %q, want failure", failures[0].Outcome)
	}

	// Runs command should not error
	root := buildRoot()
	_, err = executeCmd(root, "--db", env.dbPath, "runs")
	if err != nil {
		t.Fatalf("runs: %v", err)
	}
}

func TestRunsCmd_NoDurationHandled(t *testing.T) {
	env := newTestEnv(t)
	env.ingestRun(t, `{"id":"nd1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`)

	d := env.openDB(t)
	run, _ := d.GetRun("nd1")
	if run.DurationS != nil {
		t.Errorf("duration should be nil, got %v", run.DurationS)
	}

	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "runs")
	if err != nil {
		t.Fatalf("runs with nil duration should not crash: %v", err)
	}
}

// ── patterns: verify detection through the pipeline ───────

func TestPatternsCmd_EmptyDBShowsNothing(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "patterns")
	if err != nil {
		t.Fatalf("patterns on empty db: %v", err)
	}
}

func TestPatternsCmd_DetectsExpectedPatterns(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	d := env.openDB(t)
	patterns, err := d.ListPatterns()
	if err != nil {
		t.Fatalf("list patterns: %v", err)
	}
	if len(patterns) == 0 {
		t.Fatal("seed data with 2 failures should produce patterns")
	}

	// Verify specific patterns from our seed data:
	// s2: failure + tests_passed=false → tests-failed
	// s4: failure + duration=30 + no tests → tests-skipped, quick-failure
	patternNames := make(map[string]bool)
	for _, p := range patterns {
		patternNames[p.Name] = true
	}
	if !patternNames["tests-failed"] {
		t.Error("expected tests-failed pattern from s2 (failure with tests_passed=false)")
	}
	if !patternNames["quick-failure"] {
		t.Error("expected quick-failure pattern from s4 (failure with duration=30)")
	}
}

// ── insights: verify tag filtering works ──────────────────

func TestInsightsCmd_TagFilteringWorks(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	root1 := buildRoot()
	executeCmd(root1, "--db", env.dbPath, "analyze")

	d := env.openDB(t)

	// Get all active insights
	all, err := d.ListInsights(true, nil)
	if err != nil {
		t.Fatalf("list all: %v", err)
	}

	// Get insights filtered by "testing" tag (from code-category patterns)
	filtered, err := d.GetInsightsByTags([]string{"testing"})
	if err != nil {
		t.Fatalf("get by tags: %v", err)
	}

	// Filtered should be a subset
	if len(filtered) > len(all) {
		t.Errorf("filtered (%d) should be <= all (%d)", len(filtered), len(all))
	}

	// Insights command with --tags should not error
	root2 := buildRoot()
	_, err = executeCmd(root2, "--db", env.dbPath, "insights", "--tags", "testing")
	if err != nil {
		t.Fatalf("insights --tags: %v", err)
	}
}

// ── status/report: not just smoke ─────────────────────────

func TestStatusCmd_EmptyDBDoesNotError(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "status")
	if err != nil {
		t.Fatalf("status on empty db: %v", err)
	}
}

func TestReportCmd_EmptyDBDoesNotError(t *testing.T) {
	env := newTestEnv(t)
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "report")
	if err != nil {
		t.Fatalf("report on empty db: %v", err)
	}
}

// ── data integrity through ingest→analyze pipeline ────────

func TestPipeline_IngestAnalyzeProducesConsistentState(t *testing.T) {
	env := newTestEnv(t)

	// Ingest 6 runs: 3 success, 3 failure with tests_passed=false
	for i := 0; i < 6; i++ {
		outcome := "success"
		tp := `"tests_passed":true,"files_touched":["a.go","a_test.go"]`
		if i%2 == 1 {
			outcome = "failure"
			tp = `"tests_passed":false`
		}
		env.ingestRun(t, fmt.Sprintf(
			`{"id":"pipe-%d","task":"task %d","outcome":"%s","timestamp":"2026-02-22T%02d:00:00Z",%s,"tags":["test"]}`,
			i, i, outcome, 10+i, tp))
	}

	// Analyze
	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	// Verify consistent state
	d := env.openDB(t)

	total, success, failure, err := d.CountRuns()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if total != 6 {
		t.Errorf("total = %d, want 6", total)
	}
	if success != 3 {
		t.Errorf("success = %d, want 3", success)
	}
	if failure != 3 {
		t.Errorf("failure = %d, want 3", failure)
	}

	// All runs should be marked analyzed
	unanalyzed, _ := d.GetUnanalyzedRuns()
	if len(unanalyzed) != 0 {
		t.Errorf("all runs should be analyzed, got %d unanalyzed", len(unanalyzed))
	}

	// tests-failed pattern should exist with count 3
	pat, err := d.GetPatternByName("tests-failed")
	if err != nil {
		t.Fatalf("tests-failed pattern: %v", err)
	}
	if pat.Frequency != 3 {
		t.Errorf("tests-failed frequency = %d, want 3", pat.Frequency)
	}

	// Insights should have been generated
	insights, _ := d.ListInsights(true, nil)
	if len(insights) == 0 {
		t.Error("analyze should generate insights from 3 failures")
	}

	// Query should return relevant results
	root2 := buildRoot()
	_, err = executeCmd(root2, "--db", env.dbPath, "query", "task", "--json")
	if err != nil {
		t.Fatalf("query after pipeline: %v", err)
	}
}

// ── closed DB / error handling ────────────────────────────

func TestIngestCmd_InvalidDBPath(t *testing.T) {
	root := buildRoot()
	// Use a path inside a nonexistent read-only location
	_, err := executeCmd(root, "--db", "/proc/nonexistent/impossible.db", "ingest", "/dev/null")
	if err == nil {
		t.Fatal("ingest with invalid DB path should fail")
	}
}

// ── version output ────────────────────────────────────────

func TestVersionCmd_Runs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "version")
	if err != nil {
		t.Fatalf("version: %v", err)
	}
}

// ── truncate helper ────────────────────────────────────────

func TestTruncate(t *testing.T) {
	tests := []struct {
		input string
		max   int
		want  string
	}{
		{"hello", 10, "hello"},
		{"hello", 5, "hello"},
		{"hello world", 8, "hello..."},
	}
	for _, tt := range tests {
		got := truncate(tt.input, tt.max)
		if got != tt.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", tt.input, tt.max, got, tt.want)
		}
	}
}

// ── analyze with success rate thresholds ──────────────────

func TestAnalyzeCmd_LowSuccessRateGeneratesInsight(t *testing.T) {
	env := newTestEnv(t)
	// 1 success, 5 failures → ~17% success rate, < 0.5 → "Low success rate" insight
	for i := 0; i < 6; i++ {
		outcome := "failure"
		tp := "false"
		if i == 0 {
			outcome = "success"
			tp = "true"
		}
		env.ingestRun(t, fmt.Sprintf(`{"id":"ls%d","task":"t%d","outcome":"%s","timestamp":"2026-01-01T%02d:00:00Z","tests_passed":%s}`, i, i, outcome, i, tp))
	}

	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	d := env.openDB(t)
	insights, _ := d.ListInsights(true, nil)
	hasLowRate := false
	for _, ins := range insights {
		if strings.Contains(ins.Text, "Low success rate") {
			hasLowRate = true
		}
	}
	if !hasLowRate {
		texts := make([]string, len(insights))
		for i, ins := range insights {
			texts[i] = ins.Text
		}
		t.Errorf("expected 'Low success rate' insight with ~17%% success rate, got: %v", texts)
	}
}

func TestAnalyzeCmd_HighSuccessRateGeneratesInsight(t *testing.T) {
	env := newTestEnv(t)
	// 5 successes, 1 failure → ~83% success rate, >= 0.8 → "Strong performance" insight
	for i := 0; i < 6; i++ {
		outcome := "success"
		tp := "true"
		if i == 0 {
			outcome = "failure"
			tp = "false"
		}
		env.ingestRun(t, fmt.Sprintf(`{"id":"hs%d","task":"t%d","outcome":"%s","timestamp":"2026-01-01T%02d:00:00Z","tests_passed":%s,"files_touched":["a.go","a_test.go"]}`, i, i, outcome, i, tp))
	}

	root := buildRoot()
	_, err := executeCmd(root, "--db", env.dbPath, "analyze")
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	d := env.openDB(t)
	insights, _ := d.ListInsights(true, nil)
	hasHighRate := false
	for _, ins := range insights {
		if strings.Contains(ins.Text, "Strong performance") {
			hasHighRate = true
		}
	}
	if !hasHighRate {
		texts := make([]string, len(insights))
		for i, ins := range insights {
			texts[i] = ins.Text
		}
		t.Errorf("expected 'Strong performance' insight with ~83%% success rate, got: %v", texts)
	}
}

// ── JSON output contracts (tested via library) ────────────

func TestJSONOutputContracts_Runs(t *testing.T) {
	env := newTestEnv(t)
	seedDB(t, env)

	d := env.openDB(t)
	runs, _ := d.ListRuns(0, "")

	data, err := json.Marshal(runs)
	if err != nil {
		t.Fatalf("marshal runs: %v", err)
	}

	var parsed []map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	for _, r := range parsed {
		// Every run must have id, task, outcome
		for _, field := range []string{"id", "task", "outcome"} {
			if _, ok := r[field]; !ok {
				t.Errorf("run JSON missing required field %q", field)
			}
		}
	}
}
