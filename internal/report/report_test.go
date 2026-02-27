package report

import (
	"bytes"
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

func TestReportEmpty(t *testing.T) {
	d := testDB(t)
	r := New(d)

	rpt, err := r.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	if rpt.TotalRuns != 0 {
		t.Errorf("total = %d, want 0", rpt.TotalRuns)
	}

	var buf bytes.Buffer
	rpt.WriteHuman(&buf)
	if !strings.Contains(buf.String(), "No data yet") {
		t.Error("empty report should show onboarding message")
	}
}

func TestReportWithData(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	runs := []string{
		`{"id":"r1","task":"t1","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true}`,
		`{"id":"r2","task":"t2","outcome":"failure","timestamp":"2026-01-01T01:00:00Z","tests_passed":false}`,
		`{"id":"r3","task":"t3","outcome":"success","timestamp":"2026-01-01T02:00:00Z","tests_passed":true}`,
	}
	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	r := New(d)
	rpt, err := r.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	if rpt.TotalRuns != 3 {
		t.Errorf("total = %d, want 3", rpt.TotalRuns)
	}
	if rpt.SuccessRuns != 2 {
		t.Errorf("success = %d, want 2", rpt.SuccessRuns)
	}
}

func TestWriteHumanWithRuns(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	runs := []string{
		`{"id":"r1","task":"t1","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true}`,
		`{"id":"r2","task":"t2","outcome":"failure","timestamp":"2026-01-01T01:00:00Z","tests_passed":false}`,
		`{"id":"r3","task":"t3","outcome":"success","timestamp":"2026-01-01T02:00:00Z","tests_passed":true}`,
	}
	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	r := New(d)
	rpt, err := r.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	var buf bytes.Buffer
	rpt.WriteHuman(&buf)
	out := buf.String()

	if !strings.Contains(out, "3 total") {
		t.Errorf("should show total runs: %s", out)
	}
	if !strings.Contains(out, "2 success") {
		t.Errorf("should show success count: %s", out)
	}
	if !strings.Contains(out, "1 failure") {
		t.Errorf("should show failure count: %s", out)
	}
	if !strings.Contains(out, "67%") {
		t.Errorf("should show success rate ~67%%: %s", out)
	}
	if strings.Contains(out, "No data yet") {
		t.Error("should NOT show onboarding message when data exists")
	}
}

func TestWriteHumanSuccessRateColors(t *testing.T) {
	tests := []struct {
		name string
		rate float64
	}{
		{"high rate >= 0.75", 0.85},
		{"medium rate 0.5-0.75", 0.60},
		{"low rate < 0.5", 0.30},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rpt := &Report{
				TotalRuns:   10,
				SuccessRuns: int(tt.rate * 10),
				FailureRuns: 10 - int(tt.rate*10),
				SuccessRate: tt.rate,
			}
			var buf bytes.Buffer
			rpt.WriteHuman(&buf)
			out := buf.String()
			if !strings.Contains(out, "Rate:") {
				t.Errorf("should show Rate: %s", out)
			}
		})
	}
}

func TestWriteHumanWithPatterns(t *testing.T) {
	rpt := &Report{
		TotalRuns:   5,
		SuccessRuns: 3,
		FailureRuns: 2,
		SuccessRate: 0.6,
		Patterns: []*db.Pattern{
			{Name: "tests-failed", Frequency: 3, Impact: "high"},
			{Name: "lint-failed", Frequency: 2, Impact: "medium"},
			{Name: "no-tests", Frequency: 1, Impact: "low"},
			{Name: "zero-freq", Frequency: 0, Impact: "high"}, // should be skipped
		},
	}

	var buf bytes.Buffer
	rpt.WriteHuman(&buf)
	out := buf.String()

	if !strings.Contains(out, "Patterns Detected") {
		t.Errorf("should show Patterns Detected header: %s", out)
	}
	if !strings.Contains(out, "tests-failed") {
		t.Errorf("should show tests-failed pattern: %s", out)
	}
	if !strings.Contains(out, "lint-failed") {
		t.Errorf("should show lint-failed pattern: %s", out)
	}
	if strings.Contains(out, "zero-freq") {
		t.Error("should skip patterns with frequency 0")
	}
}

func TestWriteHumanWithInsights(t *testing.T) {
	rpt := &Report{
		TotalRuns:   5,
		SuccessRuns: 3,
		FailureRuns: 2,
		SuccessRate: 0.6,
		Insights: []*db.Insight{
			{Text: "Always run tests before committing", Confidence: 0.95},
			{Text: "Short tasks succeed more often", Confidence: 0.80},
		},
	}

	var buf bytes.Buffer
	rpt.WriteHuman(&buf)
	out := buf.String()

	if !strings.Contains(out, "Active Insights") {
		t.Errorf("should show Active Insights header: %s", out)
	}
	if !strings.Contains(out, "Always run tests") {
		t.Errorf("should show insight text: %s", out)
	}
	if !strings.Contains(out, "95%") {
		t.Errorf("should show confidence: %s", out)
	}
}

func TestWriteHumanFullReport(t *testing.T) {
	rpt := &Report{
		TotalRuns:   10,
		SuccessRuns: 8,
		FailureRuns: 2,
		SuccessRate: 0.8,
		Patterns: []*db.Pattern{
			{Name: "tests-failed", Frequency: 2, Impact: "high"},
		},
		Insights: []*db.Insight{
			{Text: "Test coverage correlates with success", Confidence: 0.90},
		},
	}

	var buf bytes.Buffer
	rpt.WriteHuman(&buf)
	out := buf.String()

	// All sections should be present
	if !strings.Contains(out, "Learning Loop Report") {
		t.Error("missing report header")
	}
	if !strings.Contains(out, "Runs:") {
		t.Error("missing runs stat")
	}
	if !strings.Contains(out, "Rate:") {
		t.Error("missing rate stat")
	}
	if !strings.Contains(out, "Patterns Detected") {
		t.Error("missing patterns section")
	}
	if !strings.Contains(out, "Active Insights") {
		t.Error("missing insights section")
	}
}

func TestReportJSON(t *testing.T) {
	d := testDB(t)
	r := New(d)

	rpt, err := r.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	var buf bytes.Buffer
	if err := rpt.WriteJSON(&buf); err != nil {
		t.Fatalf("json: %v", err)
	}

	if !strings.Contains(buf.String(), `"total_runs"`) {
		t.Error("JSON should contain total_runs")
	}
}

func TestReportJSONWithData(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	runs := []string{
		`{"id":"j1","task":"t1","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true}`,
		`{"id":"j2","task":"t2","outcome":"failure","timestamp":"2026-01-01T01:00:00Z","tests_passed":false}`,
	}
	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	r := New(d)
	rpt, err := r.Generate()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	var buf bytes.Buffer
	if err := rpt.WriteJSON(&buf); err != nil {
		t.Fatalf("json: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"total_runs"`) {
		t.Error("JSON should contain total_runs")
	}
	if !strings.Contains(out, `"success_rate"`) {
		t.Error("JSON should contain success_rate")
	}
	if !strings.Contains(out, `"patterns"`) {
		t.Error("JSON should contain patterns")
	}
	if !strings.Contains(out, `"insights"`) {
		t.Error("JSON should contain insights")
	}
}

func TestGenerateErrorOnClosedDB(t *testing.T) {
	d := testDB(t)
	r := New(d)

	// Close db to force errors from Generate
	d.Close()

	_, err := r.Generate()
	if err == nil {
		t.Fatal("Generate should fail on closed DB")
	}
	if !strings.Contains(err.Error(), "count runs") {
		t.Errorf("error should mention count runs: %v", err)
	}
}
