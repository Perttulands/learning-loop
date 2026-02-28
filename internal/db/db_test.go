package db

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func testDB(t *testing.T) *DB {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func TestOpenAndMigrate(t *testing.T) {
	d := testDB(t)
	if d.Path() == "" {
		t.Error("path should not be empty")
	}
	if _, err := os.Stat(d.Path()); err != nil {
		t.Errorf("db file should exist: %v", err)
	}
}

func TestInsertAndGetRun(t *testing.T) {
	d := testDB(t)

	dur := 120
	tp := true
	lp := true
	r := &Run{
		ID:           "run-001",
		Task:         "Fix auth bug",
		Outcome:      "success",
		DurationS:    &dur,
		Timestamp:    "2026-02-22T14:00:00Z",
		ToolsUsed:    []string{"read", "edit"},
		FilesTouched: []string{"auth.go"},
		TestsPassed:  &tp,
		LintPassed:   &lp,
		Tags:         []string{"auth", "bug"},
		Agent:        "claude",
		Model:        "opus",
	}

	if err := d.InsertRun(r); err != nil {
		t.Fatalf("insert run: %v", err)
	}

	got, err := d.GetRun("run-001")
	if err != nil {
		t.Fatalf("get run: %v", err)
	}

	if got.ID != "run-001" {
		t.Errorf("id = %q, want %q", got.ID, "run-001")
	}
	if got.Task != "Fix auth bug" {
		t.Errorf("task = %q, want %q", got.Task, "Fix auth bug")
	}
	if got.Outcome != "success" {
		t.Errorf("outcome = %q, want %q", got.Outcome, "success")
	}
	if got.DurationS == nil || *got.DurationS != 120 {
		t.Errorf("duration = %v, want 120", got.DurationS)
	}
	if got.TestsPassed == nil || !*got.TestsPassed {
		t.Error("tests_passed should be true")
	}
	if len(got.ToolsUsed) != 2 {
		t.Errorf("tools_used len = %d, want 2", len(got.ToolsUsed))
	}
	if len(got.Tags) != 2 {
		t.Errorf("tags len = %d, want 2", len(got.Tags))
	}
}

func TestListRuns(t *testing.T) {
	d := testDB(t)

	for i, outcome := range []string{"success", "failure", "success"} {
		r := &Run{
			ID:        fmt.Sprintf("run-%03d", i),
			Task:      fmt.Sprintf("Task %d", i),
			Outcome:   outcome,
			Timestamp: fmt.Sprintf("2026-02-22T%02d:00:00Z", i+10),
		}
		if err := d.InsertRun(r); err != nil {
			t.Fatalf("insert run %d: %v", i, err)
		}
	}

	// List all
	runs, err := d.ListRuns(0, "")
	if err != nil {
		t.Fatalf("list runs: %v", err)
	}
	if len(runs) != 3 {
		t.Errorf("len = %d, want 3", len(runs))
	}

	// List with limit
	runs, err = d.ListRuns(2, "")
	if err != nil {
		t.Fatalf("list runs limited: %v", err)
	}
	if len(runs) != 2 {
		t.Errorf("len = %d, want 2", len(runs))
	}

	// List by outcome
	runs, err = d.ListRuns(0, "failure")
	if err != nil {
		t.Fatalf("list runs filtered: %v", err)
	}
	if len(runs) != 1 {
		t.Errorf("len = %d, want 1", len(runs))
	}
}

func TestRunExists(t *testing.T) {
	d := testDB(t)

	exists, err := d.RunExists("nonexistent")
	if err != nil {
		t.Fatalf("run exists: %v", err)
	}
	if exists {
		t.Error("should not exist")
	}

	d.InsertRun(&Run{ID: "run-x", Task: "t", Outcome: "success", Timestamp: "2026-01-01T00:00:00Z"})
	exists, err = d.RunExists("run-x")
	if err != nil {
		t.Fatalf("run exists: %v", err)
	}
	if !exists {
		t.Error("should exist")
	}
}

func TestCountRuns(t *testing.T) {
	d := testDB(t)

	d.InsertRun(&Run{ID: "r1", Task: "t", Outcome: "success", Timestamp: "2026-01-01T00:00:00Z"})
	d.InsertRun(&Run{ID: "r2", Task: "t", Outcome: "failure", Timestamp: "2026-01-01T00:00:00Z"})
	d.InsertRun(&Run{ID: "r3", Task: "t", Outcome: "success", Timestamp: "2026-01-01T00:00:00Z"})

	total, success, failure, err := d.CountRuns()
	if err != nil {
		t.Fatalf("count runs: %v", err)
	}
	if total != 3 {
		t.Errorf("total = %d, want 3", total)
	}
	if success != 2 {
		t.Errorf("success = %d, want 2", success)
	}
	if failure != 1 {
		t.Errorf("failure = %d, want 1", failure)
	}
}

func TestUnanalyzedRuns(t *testing.T) {
	d := testDB(t)

	d.InsertRun(&Run{ID: "r1", Task: "t1", Outcome: "success", Timestamp: "2026-01-01T00:00:00Z"})
	d.InsertRun(&Run{ID: "r2", Task: "t2", Outcome: "failure", Timestamp: "2026-01-02T00:00:00Z"})

	runs, err := d.GetUnanalyzedRuns()
	if err != nil {
		t.Fatalf("get unanalyzed: %v", err)
	}
	if len(runs) != 2 {
		t.Errorf("len = %d, want 2", len(runs))
	}

	d.MarkRunAnalyzed("r1")
	runs, err = d.GetUnanalyzedRuns()
	if err != nil {
		t.Fatalf("get unanalyzed after mark: %v", err)
	}
	if len(runs) != 1 {
		t.Errorf("len = %d, want 1", len(runs))
	}
	if runs[0].ID != "r2" {
		t.Errorf("id = %q, want r2", runs[0].ID)
	}
}

func TestNullableFields(t *testing.T) {
	d := testDB(t)

	// Insert run with no optional fields
	r := &Run{
		ID:        "run-minimal",
		Task:      "Minimal task",
		Outcome:   "error",
		Timestamp: "2026-02-22T14:00:00Z",
	}
	if err := d.InsertRun(r); err != nil {
		t.Fatalf("insert: %v", err)
	}

	got, err := d.GetRun("run-minimal")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.DurationS != nil {
		t.Errorf("duration should be nil, got %v", got.DurationS)
	}
	if got.TestsPassed != nil {
		t.Errorf("tests_passed should be nil, got %v", got.TestsPassed)
	}
	if got.LintPassed != nil {
		t.Errorf("lint_passed should be nil, got %v", got.LintPassed)
	}
}

func TestPatterns(t *testing.T) {
	d := testDB(t)

	p := &Pattern{
		ID:                 "pat-001",
		Name:               "tests-skipped",
		Description:        "Agent skipped running tests",
		Category:           "process",
		Impact:             "high",
		OutcomeCorrelation: "failure",
		Frequency:          1,
		FirstSeen:          "2026-02-22T14:00:00Z",
		LastSeen:           "2026-02-22T14:00:00Z",
	}

	if err := d.UpsertPattern(p); err != nil {
		t.Fatalf("upsert pattern: %v", err)
	}

	got, err := d.GetPatternByName("tests-skipped")
	if err != nil {
		t.Fatalf("get pattern: %v", err)
	}
	if got.Frequency != 1 {
		t.Errorf("frequency = %d, want 1", got.Frequency)
	}

	// Upsert again should increment
	p.Frequency = 1
	if err := d.UpsertPattern(p); err != nil {
		t.Fatalf("upsert pattern again: %v", err)
	}

	got, err = d.GetPatternByName("tests-skipped")
	if err != nil {
		t.Fatalf("get pattern after upsert: %v", err)
	}
	if got.Frequency != 2 {
		t.Errorf("frequency = %d, want 2", got.Frequency)
	}

	// List
	patterns, err := d.ListPatterns()
	if err != nil {
		t.Fatalf("list patterns: %v", err)
	}
	if len(patterns) != 1 {
		t.Errorf("len = %d, want 1", len(patterns))
	}
}

func TestPatternMatches(t *testing.T) {
	d := testDB(t)

	d.InsertRun(&Run{ID: "r1", Task: "t", Outcome: "failure", Timestamp: "2026-01-01T00:00:00Z"})
	d.UpsertPattern(&Pattern{
		ID: "p1", Name: "tests-skipped", Description: "d",
		Category: "process", Impact: "high", Frequency: 1,
		FirstSeen: "2026-01-01T00:00:00Z", LastSeen: "2026-01-01T00:00:00Z",
	})

	if err := d.AddPatternMatch("r1", "p1"); err != nil {
		t.Fatalf("add match: %v", err)
	}

	// Duplicate should not error
	if err := d.AddPatternMatch("r1", "p1"); err != nil {
		t.Fatalf("add duplicate match: %v", err)
	}

	patterns, err := d.GetPatternsForRun("r1")
	if err != nil {
		t.Fatalf("get patterns for run: %v", err)
	}
	if len(patterns) != 1 {
		t.Errorf("len = %d, want 1", len(patterns))
	}
}

func TestConn(t *testing.T) {
	d := testDB(t)
	conn := d.Conn()
	if conn == nil {
		t.Fatal("Conn() should not return nil")
	}
	// Verify the connection works
	var n int
	if err := conn.QueryRow("SELECT 1").Scan(&n); err != nil {
		t.Fatalf("Conn() should return a working connection: %v", err)
	}
	if n != 1 {
		t.Errorf("expected 1, got %d", n)
	}
}

func TestOpenEmptyPath(t *testing.T) {
	origDir, _ := os.Getwd()
	dir := t.TempDir()
	os.Chdir(dir)
	defer os.Chdir(origDir)

	d, err := Open("")
	if err != nil {
		t.Fatalf("Open with empty path: %v", err)
	}
	d.Close()
}

func TestInsights(t *testing.T) {
	d := testDB(t)

	i := &Insight{
		ID:          "ins-001",
		Text:        "Always run tests before committing",
		Confidence:  0.85,
		BasedOnRuns: 23,
		Patterns:    []string{"tests-skipped"},
		Tags:        []string{"testing"},
		Cadence:     "daily",
		Active:      true,
	}

	if err := d.InsertInsight(i); err != nil {
		t.Fatalf("insert insight: %v", err)
	}

	insights, err := d.ListInsights(true, nil)
	if err != nil {
		t.Fatalf("list insights: %v", err)
	}
	if len(insights) != 1 {
		t.Errorf("len = %d, want 1", len(insights))
	}
	if insights[0].Text != "Always run tests before committing" {
		t.Errorf("text = %q", insights[0].Text)
	}

	// Filter by tag
	insights, err = d.ListInsights(true, []string{"testing"})
	if err != nil {
		t.Fatalf("list insights by tag: %v", err)
	}
	if len(insights) != 1 {
		t.Errorf("len = %d, want 1", len(insights))
	}

	insights, err = d.ListInsights(true, []string{"unrelated"})
	if err != nil {
		t.Fatalf("list insights unrelated tag: %v", err)
	}
	if len(insights) != 0 {
		t.Errorf("len = %d, want 0", len(insights))
	}

	// Deactivate
	if err := d.DeactivateInsight("ins-001"); err != nil {
		t.Fatalf("deactivate: %v", err)
	}
	insights, err = d.ListInsights(true, nil)
	if err != nil {
		t.Fatalf("list after deactivate: %v", err)
	}
	if len(insights) != 0 {
		t.Errorf("len = %d, want 0", len(insights))
	}

	// Count
	count, err := d.CountInsights()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Errorf("count = %d, want 0 (deactivated)", count)
	}
}
