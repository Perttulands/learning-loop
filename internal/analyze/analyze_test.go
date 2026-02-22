package analyze

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/polis/learning-loop/internal/db"
	"github.com/polis/learning-loop/internal/ingest"
)

func testDB(t *testing.T) *db.DB {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func seedRuns(t *testing.T, d *db.DB) {
	t.Helper()
	ing := ingest.New(d)

	runs := []string{
		`{"id":"r1","task":"Fix auth bug","outcome":"success","timestamp":"2026-02-22T10:00:00Z","duration_seconds":300,"tests_passed":true,"tags":["auth"],"files_touched":["auth.go","auth_test.go"]}`,
		`{"id":"r2","task":"Fix login flow","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","duration_seconds":120,"tests_passed":false,"tags":["auth"],"files_touched":["login.go"]}`,
		`{"id":"r3","task":"Add feature","outcome":"success","timestamp":"2026-02-22T12:00:00Z","duration_seconds":450,"tests_passed":true,"tags":["feature"],"files_touched":["user.go","user_test.go"]}`,
		`{"id":"r4","task":"Fix db pool","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","duration_seconds":30,"tags":["database"],"files_touched":["db.go"]}`,
		`{"id":"r5","task":"Refactor auth","outcome":"success","timestamp":"2026-02-22T14:00:00Z","duration_seconds":200,"tests_passed":true,"tags":["auth"],"files_touched":["auth.go","token.go"]}`,
		`{"id":"r6","task":"Fix rate limit","outcome":"failure","timestamp":"2026-02-22T15:00:00Z","tests_passed":false,"tags":["auth"],"files_touched":["rate.go"]}`,
	}

	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed run: %v", err)
		}
	}
}

func TestAnalyzeBasic(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	if result.RunsAnalyzed != 6 {
		t.Errorf("runs analyzed = %d, want 6", result.RunsAnalyzed)
	}

	if result.Stats.TotalRuns != 6 {
		t.Errorf("total runs = %d, want 6", result.Stats.TotalRuns)
	}

	if result.Stats.SuccessRate < 0.4 || result.Stats.SuccessRate > 0.6 {
		t.Errorf("success rate = %f, expected ~0.5", result.Stats.SuccessRate)
	}
}

func TestAnalyzeGeneratesInsights(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	if len(result.InsightsCreated) == 0 {
		t.Error("expected insights to be generated")
	}

	// Should have insight about tests-failed or tests-skipped (both occur 3+ times)
	hasTestInsight := false
	for _, ins := range result.InsightsCreated {
		if strings.Contains(ins.Text, "test") || strings.Contains(ins.Text, "Test") {
			hasTestInsight = true
			break
		}
	}
	if !hasTestInsight {
		t.Error("expected at least one test-related insight")
	}
}

func TestAnalyzePatterns(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	if len(result.PatternsFound) == 0 {
		t.Error("expected patterns to be found")
	}

	hasTestsFailed := false
	for _, p := range result.PatternsFound {
		if p.Name == "tests-failed" {
			hasTestsFailed = true
			if p.Count < 2 {
				t.Errorf("tests-failed count = %d, expected >= 2", p.Count)
			}
		}
	}
	if !hasTestsFailed {
		t.Error("expected tests-failed pattern")
	}
}

func TestAnalyzeIdempotent(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	a := New(d)

	// First analysis
	result1, err := a.Analyze()
	if err != nil {
		t.Fatalf("first analyze: %v", err)
	}
	if result1.RunsAnalyzed == 0 {
		t.Fatal("first analysis should process runs")
	}

	// Second analysis — no new runs
	result2, err := a.Analyze()
	if err != nil {
		t.Fatalf("second analyze: %v", err)
	}
	if result2.RunsAnalyzed != 0 {
		t.Errorf("second analysis processed %d runs, want 0", result2.RunsAnalyzed)
	}
}

func TestAnalyzeEmptyDB(t *testing.T) {
	d := testDB(t)
	a := New(d)

	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze empty: %v", err)
	}

	if result.RunsAnalyzed != 0 {
		t.Errorf("runs analyzed = %d, want 0", result.RunsAnalyzed)
	}
}

func TestAnalyzeStats(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	if result.Stats.AvgDuration <= 0 {
		t.Errorf("avg duration = %f, expected > 0", result.Stats.AvgDuration)
	}

	if len(result.Stats.TopTags) == 0 {
		t.Error("expected top tags")
	}

	// Auth should be the most common tag
	if result.Stats.TopTags[0].Tag != "auth" {
		t.Errorf("top tag = %q, expected 'auth'", result.Stats.TopTags[0].Tag)
	}
}

func TestAnalyzeSuccessRateInsight(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	// Seed runs with clearly low success rate (1 success, 5 failures)
	runs := []string{
		`{"id":"sr1","task":"t1","outcome":"success","timestamp":"2026-02-22T10:00:00Z","tests_passed":true,"tags":["test"]}`,
		`{"id":"sr2","task":"t2","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","tests_passed":false,"tags":["test"]}`,
		`{"id":"sr3","task":"t3","outcome":"failure","timestamp":"2026-02-22T12:00:00Z","tests_passed":false,"tags":["test"]}`,
		`{"id":"sr4","task":"t4","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","tests_passed":false,"tags":["test"]}`,
		`{"id":"sr5","task":"t5","outcome":"failure","timestamp":"2026-02-22T14:00:00Z","tests_passed":false,"tags":["test"]}`,
		`{"id":"sr6","task":"t6","outcome":"failure","timestamp":"2026-02-22T15:00:00Z","tests_passed":false,"tags":["test"]}`,
	}
	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	hasOverallInsight := false
	for _, ins := range result.InsightsCreated {
		if strings.Contains(ins.ID, "overall") {
			hasOverallInsight = true
			if !strings.Contains(ins.Text, "Low success rate") {
				t.Errorf("expected low success rate insight, got: %s", ins.Text)
			}
			break
		}
	}
	if !hasOverallInsight {
		t.Error("expected overall success rate insight for <50% success rate")
	}
}

func TestInsightConfidence(t *testing.T) {
	d := testDB(t)

	// Seed enough runs to trigger high-confidence insights
	ing := ingest.New(d)
	for i := 0; i < 12; i++ {
		outcome := "failure"
		r := strings.NewReader(`{"id":"conf-` + string(rune('a'+i)) + `","task":"task","outcome":"` + outcome + `","timestamp":"2026-02-22T10:00:00Z","tests_passed":false,"tags":["test"]}`)
		_, _, err := ing.IngestReader(r)
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	for _, ins := range result.InsightsCreated {
		for _, pat := range ins.Patterns {
			if pat == "tests-failed" && ins.Confidence < 0.9 {
				t.Errorf("tests-failed with 12 occurrences should have high confidence, got %f", ins.Confidence)
			}
		}
	}
}
