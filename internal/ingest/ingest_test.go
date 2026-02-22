package ingest

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/polis/learning-loop/internal/db"
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

func TestIngestValidRun(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	input := `{
		"id": "run-001",
		"task": "Fix auth bug",
		"outcome": "success",
		"duration_seconds": 120,
		"timestamp": "2026-02-22T14:00:00Z",
		"tools_used": ["read", "edit"],
		"files_touched": ["auth.go", "auth_test.go"],
		"tests_passed": true,
		"lint_passed": true,
		"tags": ["auth", "bug"],
		"agent": "claude",
		"model": "opus"
	}`

	run, patterns, err := ing.IngestReader(strings.NewReader(input))
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	if run.ID != "run-001" {
		t.Errorf("id = %q, want run-001", run.ID)
	}
	if len(patterns) != 0 {
		t.Errorf("patterns = %v, want empty (success run)", patterns)
	}

	// Verify stored
	got, err := d.GetRun("run-001")
	if err != nil {
		t.Fatalf("get run: %v", err)
	}
	if got.Task != "Fix auth bug" {
		t.Errorf("task = %q", got.Task)
	}
}

func TestIngestDuplicate(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	input := `{"id":"dup-1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`
	_, _, err := ing.IngestReader(strings.NewReader(input))
	if err != nil {
		t.Fatalf("first ingest: %v", err)
	}

	_, _, err = ing.IngestReader(strings.NewReader(input))
	if err == nil {
		t.Fatal("expected error for duplicate run")
	}
	if !strings.Contains(err.Error(), "already ingested") {
		t.Errorf("error = %q, want 'already ingested'", err.Error())
	}
}

func TestIngestMissingFields(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"no id", `{"task":"t","outcome":"success"}`, "missing required field: id"},
		{"no task", `{"id":"x","outcome":"success"}`, "missing required field: task"},
		{"no outcome", `{"id":"x","task":"t"}`, "missing required field: outcome"},
		{"bad outcome", `{"id":"x","task":"t","outcome":"maybe"}`, "invalid outcome"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := ing.IngestReader(strings.NewReader(tt.input))
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want %q", err.Error(), tt.want)
			}
		})
	}
}

func TestIngestAutoTimestamp(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	input := `{"id":"ts-1","task":"t","outcome":"success"}`
	run, _, err := ing.IngestReader(strings.NewReader(input))
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	if run.Timestamp == "" {
		t.Error("timestamp should be auto-filled")
	}
}

func TestPatternDetection(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	tests := []struct {
		name     string
		input    string
		patterns []string
	}{
		{
			"tests-failed",
			`{"id":"p1","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","tests_passed":false}`,
			[]string{"tests-failed"},
		},
		{
			"tests-skipped on failure",
			`{"id":"p2","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z"}`,
			[]string{"tests-skipped"},
		},
		{
			"lint-failed",
			`{"id":"p3","task":"t","outcome":"partial","timestamp":"2026-01-01T00:00:00Z","lint_passed":false}`,
			[]string{"tests-skipped", "lint-failed"},
		},
		{
			"scope-creep by duration",
			`{"id":"p4","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","duration_seconds":2000}`,
			[]string{"tests-skipped", "scope-creep"},
		},
		{
			"scope-creep by files",
			`{"id":"p5","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true,
			 "files_touched":["a.go","b.go","c.go","d.go","e.go","f.go","g.go","h.go","i.go"]}`,
			[]string{"scope-creep", "no-test-files"},
		},
		{
			"quick-failure",
			`{"id":"p6","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","duration_seconds":30}`,
			[]string{"tests-skipped", "quick-failure"},
		},
		{
			"long-running",
			`{"id":"p7","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","duration_seconds":4000,"tests_passed":true}`,
			[]string{"scope-creep", "long-running"},
		},
		{
			"no-test-files",
			`{"id":"p8","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true,
			 "files_touched":["auth.go","middleware.go"]}`,
			[]string{"no-test-files"},
		},
		{
			"success-with-errors",
			`{"id":"p9","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true,
			 "error_message":"warning: deprecated API"}`,
			[]string{"success-with-errors"},
		},
		{
			"clean success",
			`{"id":"p10","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z","tests_passed":true,
			 "lint_passed":true,"files_touched":["auth.go","auth_test.go"]}`,
			nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, patterns, err := ing.IngestReader(strings.NewReader(tt.input))
			if err != nil {
				t.Fatalf("ingest: %v", err)
			}
			if len(patterns) != len(tt.patterns) {
				t.Fatalf("patterns = %v, want %v", patterns, tt.patterns)
			}
			for i, p := range patterns {
				if p != tt.patterns[i] {
					t.Errorf("pattern[%d] = %q, want %q", i, p, tt.patterns[i])
				}
			}
		})
	}
}

func TestPatternFrequencyIncrement(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	for i := 0; i < 3; i++ {
		input := strings.NewReader(`{"id":"freq-` + string(rune('a'+i)) + `","task":"t","outcome":"failure","timestamp":"2026-01-01T00:00:00Z","tests_passed":false}`)
		_, _, err := ing.IngestReader(input)
		if err != nil {
			t.Fatalf("ingest %d: %v", i, err)
		}
	}

	pat, err := d.GetPatternByName("tests-failed")
	if err != nil {
		t.Fatalf("get pattern: %v", err)
	}
	if pat.Frequency != 3 {
		t.Errorf("frequency = %d, want 3", pat.Frequency)
	}
}

func TestIngestFromJSON(t *testing.T) {
	d := testDB(t)
	ing := New(d)

	data := []byte(`{"id":"json-1","task":"t","outcome":"success","timestamp":"2026-01-01T00:00:00Z"}`)
	run, _, err := ing.IngestJSON(data)
	if err != nil {
		t.Fatalf("ingest json: %v", err)
	}
	if run.ID != "json-1" {
		t.Errorf("id = %q", run.ID)
	}
}
