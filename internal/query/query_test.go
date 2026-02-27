package query

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
		`{"id":"r1","task":"Fix authentication bug in login","outcome":"success","timestamp":"2026-02-22T10:00:00Z","duration_seconds":300,"tests_passed":true,"lint_passed":true,"tags":["auth","bug"],"files_touched":["auth.go","auth_test.go"]}`,
		`{"id":"r2","task":"Fix auth middleware token validation","outcome":"failure","timestamp":"2026-02-22T11:00:00Z","duration_seconds":120,"tests_passed":false,"tags":["auth","middleware"],"files_touched":["middleware.go"]}`,
		`{"id":"r3","task":"Add user registration endpoint","outcome":"success","timestamp":"2026-02-22T12:00:00Z","duration_seconds":450,"tests_passed":true,"lint_passed":true,"tags":["user","feature"],"files_touched":["user.go","user_test.go"]}`,
		`{"id":"r4","task":"Fix database connection pooling","outcome":"failure","timestamp":"2026-02-22T13:00:00Z","duration_seconds":30,"tags":["database","bug"],"files_touched":["db.go"]}`,
		`{"id":"r5","task":"Refactor auth token refresh logic","outcome":"success","timestamp":"2026-02-22T14:00:00Z","duration_seconds":200,"tests_passed":true,"tags":["auth","refactor"],"files_touched":["auth.go","token.go","token_test.go"]}`,
		`{"id":"r6","task":"Fix login rate limiting","outcome":"partial","timestamp":"2026-02-21T10:00:00Z","duration_seconds":600,"tests_passed":true,"lint_passed":false,"tags":["auth","security"],"files_touched":["ratelimit.go"]}`,
	}

	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed run: %v", err)
		}
	}
}

func TestQueryMatchesRelevantRuns(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("fix auth bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	if result.MatchedRuns == 0 {
		t.Fatal("expected matched runs for 'fix auth bug'")
	}

	// Auth-related runs should rank higher
	if result.MatchedRuns < 3 {
		t.Errorf("matched = %d, expected at least 3 auth-related runs", result.MatchedRuns)
	}
}

func TestQuerySuccessRate(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("authentication", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	if result.SuccessRate < 0 || result.SuccessRate > 1 {
		t.Errorf("success rate = %f, out of bounds", result.SuccessRate)
	}
}

func TestQueryDetectsPatterns(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("fix bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	// Should have detected some patterns from failure runs
	hasPatterns := len(result.TopPatterns) > 0
	if !hasPatterns && result.MatchedRuns > 0 {
		// This is ok if all matched runs were successes
		for _, r := range result.RelevantRuns {
			if r.Outcome == "failure" {
				t.Error("expected patterns from failure runs")
				break
			}
		}
	}
}

func TestQueryEmptyDB(t *testing.T) {
	d := testDB(t)
	e := New(d)

	result, err := e.Query("anything", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	if result.MatchedRuns != 0 {
		t.Errorf("matched = %d, want 0", result.MatchedRuns)
	}
}

func TestQueryHumanOutput(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("fix auth bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	var buf bytes.Buffer
	result.WriteHuman(&buf)
	output := buf.String()

	if !strings.Contains(output, "LEARNINGS") {
		t.Error("human output should contain LEARNINGS header")
	}
	if !strings.Contains(output, "success") {
		t.Error("human output should mention success rate")
	}
}

func TestQueryJSONOutput(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("fix auth bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	var buf bytes.Buffer
	if err := result.WriteJSON(&buf); err != nil {
		t.Fatalf("json output: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, `"query"`) {
		t.Error("JSON output should contain query field")
	}
	if !strings.Contains(output, `"matched_runs"`) {
		t.Error("JSON output should contain matched_runs field")
	}
}

func TestQueryInjectOutput(t *testing.T) {
	d := testDB(t)
	seedRuns(t, d)

	e := New(d)
	result, err := e.Query("fix auth bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	var buf bytes.Buffer
	result.WriteInject(&buf)
	output := buf.String()

	if !strings.Contains(output, "## Learnings for:") {
		t.Error("inject output should start with markdown header")
	}
}

func TestQueryEmptyOutputGraceful(t *testing.T) {
	d := testDB(t)
	e := New(d)

	result, err := e.Query("anything", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	var buf bytes.Buffer
	result.WriteHuman(&buf)
	output := buf.String()

	if !strings.Contains(output, "No relevant learnings") {
		t.Error("empty result should show helpful message")
	}
}

func TestExtractKeywords(t *testing.T) {
	tests := []struct {
		input string
		want  int // minimum keywords expected
	}{
		{"Fix authentication bug in login middleware", 4},
		{"the a an", 0},
		{"Fix", 1},
		{"", 0},
	}

	for _, tt := range tests {
		kw := extractKeywords(tt.input)
		if len(kw) < tt.want {
			t.Errorf("extractKeywords(%q) = %v, want at least %d keywords", tt.input, kw, tt.want)
		}
	}
}

func TestScoreRunRecencyDecay(t *testing.T) {
	dur := 300
	tp := true

	makeRun := func(timestamp string) *db.Run {
		return &db.Run{
			ID:          "r1",
			Task:        "Fix authentication bug",
			Outcome:     "failure",
			DurationS:   &dur,
			Timestamp:   timestamp,
			Tags:        []string{"auth", "bug"},
			TestsPassed: &tp,
		}
	}

	now, _ := time.Parse(time.RFC3339, "2026-02-22T15:00:00Z")
	keywords := extractKeywords("fix auth bug")

	// Very recent run (1 hour ago) — decay should be near 1.0
	recentRun := makeRun("2026-02-22T14:00:00Z")
	recentScore := scoreRun(recentRun, keywords, now)

	// 7 days old — decay should be ~0.5 (half-life)
	weekOldRun := makeRun("2026-02-15T15:00:00Z")
	weekScore := scoreRun(weekOldRun, keywords, now)

	// 30 days old — decay should be very small
	monthOldRun := makeRun("2026-01-23T15:00:00Z")
	monthScore := scoreRun(monthOldRun, keywords, now)

	// 365 days old — decay should be near floor
	yearOldRun := makeRun("2025-02-22T15:00:00Z")
	yearScore := scoreRun(yearOldRun, keywords, now)

	// Scores should decrease with age
	if recentScore <= weekScore {
		t.Errorf("recent (%.2f) should score higher than week-old (%.2f)", recentScore, weekScore)
	}
	if weekScore <= monthScore {
		t.Errorf("week-old (%.2f) should score higher than month-old (%.2f)", weekScore, monthScore)
	}
	if monthScore <= yearScore {
		t.Errorf("month-old (%.2f) should score higher than year-old (%.2f)", monthScore, yearScore)
	}

	// Year-old score should still be > 50% of recent (floor at 0.5)
	if yearScore < recentScore*0.45 {
		t.Errorf("year-old (%.2f) should be at least ~50%% of recent (%.2f) due to floor", yearScore, recentScore)
	}
}

func TestScoreRunRecencyExactBoundary(t *testing.T) {
	dur := 300
	tp := true

	run := &db.Run{
		ID:          "r1",
		Task:        "Fix auth bug",
		Outcome:     "failure",
		DurationS:   &dur,
		Timestamp:   "2026-02-22T15:00:00Z",
		Tags:        []string{"auth", "bug"},
		TestsPassed: &tp,
	}

	keywords := extractKeywords("fix auth bug")

	// Score at exact same time as run
	exactTime, _ := time.Parse(time.RFC3339, "2026-02-22T15:00:00Z")
	exactScore := scoreRun(run, keywords, exactTime)

	// Score 1 second later
	justAfter, _ := time.Parse(time.RFC3339, "2026-02-22T15:00:01Z")
	justAfterScore := scoreRun(run, keywords, justAfter)

	// At exact time, decay should be 1.0 (daysSince=0)
	// Score should be very close (negligible difference)
	if exactScore < justAfterScore {
		t.Errorf("exact time score (%.4f) should be >= just-after score (%.4f)", exactScore, justAfterScore)
	}

	// Exact time score should have full decay multiplier (0.5 + 0.5*1.0 = 1.0)
	if exactScore <= 0 {
		t.Errorf("exact time score should be positive, got %.4f", exactScore)
	}
}

func TestScoreRunInvalidTimestamp(t *testing.T) {
	run := &db.Run{
		ID:        "r1",
		Task:      "Fix auth bug",
		Outcome:   "failure",
		Timestamp: "not-a-timestamp",
		Tags:      []string{"auth"},
	}

	now := time.Now()
	keywords := extractKeywords("fix auth bug")
	score := scoreRun(run, keywords, now)

	// Should still get a positive score from keyword/tag matches even without decay
	if score <= 0 {
		t.Errorf("invalid timestamp should still score from keywords, got %.2f", score)
	}
}

func TestScoreRunThresholdBoundary(t *testing.T) {
	// The query function filters at score > 0.5
	// A run with minimal keyword overlap should score near or below the threshold
	now, _ := time.Parse(time.RFC3339, "2026-02-22T15:00:00Z")

	// Run with no keyword overlap — only outcome signal
	noMatchRun := &db.Run{
		ID:        "r1",
		Task:      "Completely unrelated task about cooking",
		Outcome:   "success", // +0.3
		Timestamp: "2026-02-22T14:00:00Z",
		Tags:      []string{"cooking", "recipes"},
	}
	keywords := extractKeywords("fix database connection")
	noMatchScore := scoreRun(noMatchRun, keywords, now)

	// With only outcome signal (0.3) * decay, should be below 0.5 threshold
	if noMatchScore > 0.5 {
		t.Errorf("no-match run scored %.2f, expected <= 0.5", noMatchScore)
	}

	// Run with partial keyword overlap — should be above threshold
	partialRun := &db.Run{
		ID:        "r2",
		Task:      "Fix the database schema",
		Outcome:   "failure",
		Timestamp: "2026-02-22T14:00:00Z",
		Tags:      []string{"database"},
	}
	partialScore := scoreRun(partialRun, keywords, now)

	if partialScore <= 0.5 {
		t.Errorf("partial-match run scored %.2f, expected > 0.5", partialScore)
	}
}

func TestQueryThresholdFiltering(t *testing.T) {
	d := testDB(t)
	ing := ingest.New(d)

	// Seed runs: one very relevant, one completely irrelevant
	runs := []string{
		`{"id":"rel-1","task":"Fix authentication bug in login","outcome":"failure","timestamp":"2026-02-22T10:00:00Z","tags":["auth","bug"]}`,
		`{"id":"irrel-1","task":"Cook pasta for dinner","outcome":"success","timestamp":"2026-02-22T11:00:00Z","tags":["cooking","food"]}`,
	}
	for _, r := range runs {
		_, _, err := ing.IngestReader(strings.NewReader(r))
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	e := New(d)
	result, err := e.Query("fix auth bug", 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	// Irrelevant run should be filtered out by threshold
	for _, r := range result.RelevantRuns {
		if r.ID == "irrel-1" {
			t.Error("irrelevant 'cooking' run should be filtered out by relevance threshold")
		}
	}

	// Relevant run should be included
	found := false
	for _, r := range result.RelevantRuns {
		if r.ID == "rel-1" {
			found = true
		}
	}
	if !found {
		t.Error("relevant 'auth bug' run should be included")
	}
}

func TestScoreRunRelevance(t *testing.T) {
	dur := 300
	tp := true

	authRun := &db.Run{
		ID:        "auth-1",
		Task:      "Fix authentication bug",
		Outcome:   "failure",
		DurationS: &dur,
		Timestamp: "2026-02-22T14:00:00Z",
		Tags:      []string{"auth", "bug"},
		TestsPassed: &tp,
	}

	dbRun := &db.Run{
		ID:        "db-1",
		Task:      "Fix database connection",
		Outcome:   "success",
		DurationS: &dur,
		Timestamp: "2026-02-22T14:00:00Z",
		Tags:      []string{"database"},
		TestsPassed: &tp,
	}

	now, _ := time.Parse(time.RFC3339, "2026-02-22T15:00:00Z")
	keywords := extractKeywords("fix auth bug")

	authScore := scoreRun(authRun, keywords, now)
	dbScore := scoreRun(dbRun, keywords, now)

	if authScore <= dbScore {
		t.Errorf("auth run (score=%.2f) should rank higher than db run (score=%.2f) for 'fix auth bug'",
			authScore, dbScore)
	}
}
