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
