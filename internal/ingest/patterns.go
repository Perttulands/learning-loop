package ingest

import (
	"fmt"
	"strings"

	"github.com/polis/learning-loop/internal/db"
)

type patternRule struct {
	Name        string
	Description string
	Category    string
	Impact      string
	Correlation string
	Match       func(r *db.Run) bool
}

var builtinPatterns = []patternRule{
	{
		Name:        "tests-skipped",
		Description: "Agent completed the task but did not run tests",
		Category:    "process",
		Impact:      "high",
		Correlation: "failure",
		Match: func(r *db.Run) bool {
			return r.Outcome != "success" && r.TestsPassed == nil
		},
	},
	{
		Name:        "tests-failed",
		Description: "Tests were run but failed",
		Category:    "code",
		Impact:      "high",
		Correlation: "failure",
		Match: func(r *db.Run) bool {
			return r.TestsPassed != nil && !*r.TestsPassed
		},
	},
	{
		Name:        "lint-failed",
		Description: "Linter was run but found issues",
		Category:    "code",
		Impact:      "medium",
		Correlation: "partial",
		Match: func(r *db.Run) bool {
			return r.LintPassed != nil && !*r.LintPassed
		},
	},
	{
		Name:        "scope-creep",
		Description: "Task took too long or touched too many files, suggesting scope expansion",
		Category:    "scope",
		Impact:      "medium",
		Correlation: "failure",
		Match: func(r *db.Run) bool {
			if r.DurationS != nil && *r.DurationS > 1800 {
				return true
			}
			return len(r.FilesTouched) > 8
		},
	},
	{
		Name:        "quick-failure",
		Description: "Task failed very quickly, suggesting a fundamental misunderstanding or blocker",
		Category:    "process",
		Impact:      "high",
		Correlation: "failure",
		Match: func(r *db.Run) bool {
			return r.Outcome == "failure" && r.DurationS != nil && *r.DurationS < 60
		},
	},
	{
		Name:        "long-running",
		Description: "Task took over an hour, suggesting high complexity or inefficiency",
		Category:    "scope",
		Impact:      "medium",
		Correlation: "partial",
		Match: func(r *db.Run) bool {
			return r.DurationS != nil && *r.DurationS > 3600
		},
	},
	{
		Name:        "no-test-files",
		Description: "Source files were modified but no test files were touched",
		Category:    "process",
		Impact:      "medium",
		Correlation: "failure",
		Match: func(r *db.Run) bool {
			if len(r.FilesTouched) == 0 {
				return false
			}
			hasSource := false
			hasTest := false
			for _, f := range r.FilesTouched {
				lower := strings.ToLower(f)
				if strings.Contains(lower, "_test") || strings.Contains(lower, ".test.") || strings.Contains(lower, "test_") {
					hasTest = true
				} else if strings.HasSuffix(lower, ".go") || strings.HasSuffix(lower, ".ts") ||
					strings.HasSuffix(lower, ".js") || strings.HasSuffix(lower, ".py") ||
					strings.HasSuffix(lower, ".rs") || strings.HasSuffix(lower, ".java") {
					hasSource = true
				}
			}
			return hasSource && !hasTest
		},
	},
	{
		Name:        "success-with-errors",
		Description: "Task was marked successful but had an error message",
		Category:    "process",
		Impact:      "medium",
		Correlation: "partial",
		Match: func(r *db.Run) bool {
			return r.Outcome == "success" && r.ErrorMessage != ""
		},
	},
}

func detectAndStore(database *db.DB, run *db.Run) ([]string, error) {
	var matched []string

	for _, rule := range builtinPatterns {
		if !rule.Match(run) {
			continue
		}

		patternID := fmt.Sprintf("pat-%s", rule.Name)
		p := &db.Pattern{
			ID:                 patternID,
			Name:               rule.Name,
			Description:        rule.Description,
			Category:           rule.Category,
			Impact:             rule.Impact,
			OutcomeCorrelation: rule.Correlation,
			Frequency:          1,
			FirstSeen:          run.Timestamp,
			LastSeen:           run.Timestamp,
		}

		if err := database.UpsertPattern(p); err != nil {
			return matched, fmt.Errorf("upsert pattern %s: %w", rule.Name, err)
		}

		if err := database.AddPatternMatch(run.ID, patternID); err != nil {
			return matched, fmt.Errorf("add pattern match %s: %w", rule.Name, err)
		}

		matched = append(matched, rule.Name)
	}

	return matched, nil
}
