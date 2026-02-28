package analyze

import (
	"fmt"
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

// ── inferTags: documents which category maps to which tags ─
// This matters because insights are filtered by tag in the CLI.
// If these mappings change silently, --tags filtering breaks.

func TestInferTags(t *testing.T) {
	tests := []struct {
		category string
		want     []string
	}{
		{"process", []string{"process", "workflow"}},
		{"code", []string{"code-quality", "testing"}},
		{"scope", []string{"scope", "efficiency"}},
		{"custom-thing", []string{"custom-thing"}}, // default fallback
	}
	for _, tt := range tests {
		t.Run(tt.category, func(t *testing.T) {
			got := inferTags(&db.Pattern{Category: tt.category})
			if len(got) != len(tt.want) {
				t.Fatalf("inferTags(%q) = %v, want %v", tt.category, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("inferTags(%q)[%d] = %q, want %q", tt.category, i, got[i], tt.want[i])
				}
			}
		})
	}
}

// ── generateInsightText coverage ──────────────────────────

func TestGenerateInsightText_AllPatterns(t *testing.T) {
	stats := Stats{TotalRuns: 10, SuccessRate: 0.5}

	tests := []struct {
		name     string
		pattern  *db.Pattern
		contains string
	}{
		{"tests-skipped", &db.Pattern{Name: "tests-skipped", Frequency: 5}, "Tests were skipped"},
		{"tests-failed", &db.Pattern{Name: "tests-failed", Frequency: 3}, "Tests failed"},
		{"lint-failed", &db.Pattern{Name: "lint-failed", Frequency: 4}, "Linter issues"},
		{"scope-creep", &db.Pattern{Name: "scope-creep", Frequency: 2}, "Scope creep"},
		{"quick-failure", &db.Pattern{Name: "quick-failure", Frequency: 6}, "Quick failures"},
		{"long-running", &db.Pattern{Name: "long-running", Frequency: 1}, "Tasks ran over"},
		{"no-test-files", &db.Pattern{Name: "no-test-files", Frequency: 3}, "Source files were edited"},
		{"success-with-errors", &db.Pattern{Name: "success-with-errors", Frequency: 2}, "marked successful despite errors"},
		{"unknown-pattern", &db.Pattern{Name: "unknown-pattern", Frequency: 1, Description: "some desc"}, "Pattern 'unknown-pattern'"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			text := generateInsightText(tt.pattern, stats)
			if text == "" {
				t.Fatal("expected non-empty text")
			}
			if !strings.Contains(text, tt.contains) {
				t.Errorf("text = %q, want to contain %q", text, tt.contains)
			}
		})
	}
}

func TestGenerateInsightText_ZeroTotalRuns(t *testing.T) {
	stats := Stats{TotalRuns: 0}
	p := &db.Pattern{Name: "tests-skipped", Frequency: 1}
	text := generateInsightText(p, stats)
	if text == "" {
		t.Fatal("expected non-empty text even with zero total runs")
	}
}

// ── generateInsights coverage ─────────────────────────────

func TestGenerateInsights_HighSuccessRate(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	// 5 successes, 1 failure → 83% success rate, >= 0.8 triggers "Strong performance"
	for i := 0; i < 5; i++ {
		r := strings.NewReader(fmt.Sprintf(`{"id":"hsr-%d","task":"t","outcome":"success","timestamp":"2026-02-22T%02d:00:00Z","tests_passed":true,"files_touched":["a.go","a_test.go"]}`, i, 10+i))
		_, _, err := ing.IngestReader(r)
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	r := strings.NewReader(`{"id":"hsr-fail","task":"t","outcome":"failure","timestamp":"2026-02-22T15:00:00Z","tests_passed":false}`)
	ing.IngestReader(r)

	a := New(d)
	result, err := a.Analyze()
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}

	hasStrongPerf := false
	for _, ins := range result.InsightsCreated {
		if strings.Contains(ins.Text, "Strong performance") {
			hasStrongPerf = true
			break
		}
	}
	if !hasStrongPerf {
		t.Error("expected 'Strong performance' insight for high success rate")
	}
}

func TestGenerateInsights_MediumConfidence(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	// Seed 6 failures to trigger frequency >= 5 (medium confidence = 0.75)
	for i := 0; i < 6; i++ {
		r := strings.NewReader(fmt.Sprintf(`{"id":"mc-%d","task":"t","outcome":"failure","timestamp":"2026-02-22T%02d:00:00Z","tests_passed":false}`, i, 10+i))
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
			if pat == "tests-failed" && ins.Confidence != 0.75 {
				t.Errorf("tests-failed with 6 occurrences should have confidence 0.75, got %f", ins.Confidence)
			}
		}
	}
}

func TestGenerateInsights_SkipsLowFrequency(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	// Only 2 failures — frequency < 3, should not generate pattern insights
	for i := 0; i < 2; i++ {
		r := strings.NewReader(fmt.Sprintf(`{"id":"lf-%d","task":"t","outcome":"failure","timestamp":"2026-02-22T%02d:00:00Z","tests_passed":false}`, i, 10+i))
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
		if len(ins.Patterns) > 0 {
			t.Errorf("expected no pattern-based insights for frequency < 3, got: %v", ins.Patterns)
		}
	}
}

// ── GetInsightsByTags coverage (db function at 0%) ────────

func TestGetInsightsByTags(t *testing.T) {
	d := testDB(t)

	// Insert test insights
	ins1 := &db.Insight{
		ID: "gbt-1", Text: "Test insight 1", Confidence: 0.8,
		BasedOnRuns: 5, Tags: []string{"testing", "code-quality"},
		Cadence: "analysis", Active: true,
	}
	ins2 := &db.Insight{
		ID: "gbt-2", Text: "Test insight 2", Confidence: 0.7,
		BasedOnRuns: 3, Tags: []string{"process", "workflow"},
		Cadence: "analysis", Active: true,
	}
	ins3 := &db.Insight{
		ID: "gbt-3", Text: "Inactive insight", Confidence: 0.6,
		BasedOnRuns: 2, Tags: []string{"testing"},
		Cadence: "analysis", Active: false,
	}

	d.InsertInsight(ins1)
	d.InsertInsight(ins2)
	d.InsertInsight(ins3)

	// Get by testing tag — should return only ins1 (active with matching tag)
	results, err := d.GetInsightsByTags([]string{"testing"})
	if err != nil {
		t.Fatalf("GetInsightsByTags: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 insight with 'testing' tag, got %d", len(results))
	}
	if results[0].ID != "gbt-1" {
		t.Errorf("expected gbt-1, got %s", results[0].ID)
	}

	// Get by process tag — should return ins2
	results, err = d.GetInsightsByTags([]string{"process"})
	if err != nil {
		t.Fatalf("GetInsightsByTags: %v", err)
	}
	if len(results) != 1 || results[0].ID != "gbt-2" {
		t.Errorf("expected gbt-2 for 'process' tag, got %v", results)
	}

	// Get by nonexistent tag — should be empty
	results, err = d.GetInsightsByTags([]string{"nonexistent"})
	if err != nil {
		t.Fatalf("GetInsightsByTags: %v", err)
	}
	if len(results) != 0 {
		t.Errorf("expected 0 for nonexistent tag, got %d", len(results))
	}
}

// ── InsertInsight with ExpiresAt ──────────────────────────

func TestInsertInsight_WithExpiry(t *testing.T) {
	d := testDB(t)
	ins := &db.Insight{
		ID: "exp-1", Text: "Expiring insight", Confidence: 0.7,
		BasedOnRuns: 3, Tags: []string{"test"},
		Cadence: "daily", Active: true,
		ExpiresAt: "2026-03-01T00:00:00Z",
	}
	if err := d.InsertInsight(ins); err != nil {
		t.Fatalf("insert: %v", err)
	}

	results, err := d.ListInsights(true, nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1, got %d", len(results))
	}
	if results[0].ExpiresAt != "2026-03-01T00:00:00Z" {
		t.Errorf("expires_at = %q, want 2026-03-01T00:00:00Z", results[0].ExpiresAt)
	}
}

func TestInsertInsight_Inactive(t *testing.T) {
	d := testDB(t)
	ins := &db.Insight{
		ID: "inact-1", Text: "Inactive", Confidence: 0.5,
		BasedOnRuns: 1, Cadence: "analysis", Active: false,
	}
	if err := d.InsertInsight(ins); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// Active-only query should not return it
	results, err := d.ListInsights(true, nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(results) != 0 {
		t.Errorf("expected 0 active insights, got %d", len(results))
	}

	// All (including inactive) should return it
	results, err = d.ListInsights(false, nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(results) != 1 {
		t.Errorf("expected 1 insight (inactive), got %d", len(results))
	}
}
