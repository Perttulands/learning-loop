package analyze

import (
	"fmt"
	"strings"

	"github.com/polis/learning-loop/internal/db"
)

type Analyzer struct {
	db *db.DB
}

type AnalysisResult struct {
	RunsAnalyzed    int               `json:"runs_analyzed"`
	PatternsFound   []PatternSummary  `json:"patterns_found"`
	InsightsCreated []*db.Insight     `json:"insights_created"`
	Stats           Stats             `json:"stats"`
}

type PatternSummary struct {
	Name      string `json:"name"`
	Count     int    `json:"count"`
	Impact    string `json:"impact"`
}

type Stats struct {
	TotalRuns   int     `json:"total_runs"`
	SuccessRate float64 `json:"success_rate"`
	FailureRate float64 `json:"failure_rate"`
	AvgDuration float64 `json:"avg_duration_seconds"`
	TopTags     []TagCount `json:"top_tags"`
}

type TagCount struct {
	Tag   string `json:"tag"`
	Count int    `json:"count"`
}

func New(database *db.DB) *Analyzer {
	return &Analyzer{db: database}
}

func (a *Analyzer) Analyze() (*AnalysisResult, error) {
	runs, err := a.db.GetUnanalyzedRuns()
	if err != nil {
		return nil, fmt.Errorf("get unanalyzed runs: %w", err)
	}

	if len(runs) == 0 {
		return &AnalysisResult{}, nil
	}

	// Compute stats across all runs (not just unanalyzed)
	stats, err := a.computeStats()
	if err != nil {
		return nil, fmt.Errorf("compute stats: %w", err)
	}

	// Get current patterns
	patterns, err := a.db.ListPatterns()
	if err != nil {
		return nil, fmt.Errorf("list patterns: %w", err)
	}

	var patternSummaries []PatternSummary
	for _, p := range patterns {
		if p.Frequency > 0 {
			patternSummaries = append(patternSummaries, PatternSummary{
				Name:   p.Name,
				Count:  p.Frequency,
				Impact: p.Impact,
			})
		}
	}

	// Generate insights from patterns and stats
	insights := a.generateInsights(patterns, stats)
	for _, ins := range insights {
		if err := a.db.InsertInsight(ins); err != nil {
			// Skip duplicates
			if !strings.Contains(err.Error(), "UNIQUE") {
				return nil, fmt.Errorf("insert insight: %w", err)
			}
		}
	}

	// Mark runs as analyzed
	for _, run := range runs {
		if err := a.db.MarkRunAnalyzed(run.ID); err != nil {
			return nil, fmt.Errorf("mark run analyzed: %w", err)
		}
	}

	return &AnalysisResult{
		RunsAnalyzed:    len(runs),
		PatternsFound:   patternSummaries,
		InsightsCreated: insights,
		Stats:           stats,
	}, nil
}

func (a *Analyzer) computeStats() (Stats, error) {
	total, success, failure, err := a.db.CountRuns()
	if err != nil {
		return Stats{}, fmt.Errorf("count runs: %w", err)
	}

	stats := Stats{
		TotalRuns: total,
	}
	if total > 0 {
		stats.SuccessRate = float64(success) / float64(total)
		stats.FailureRate = float64(failure) / float64(total)
	}

	// Compute average duration and top tags
	allRuns, err := a.db.ListRuns(0, "")
	if err != nil {
		return stats, fmt.Errorf("list all runs: %w", err)
	}

	var totalDuration int
	var durationCount int
	tagCounts := make(map[string]int)

	for _, run := range allRuns {
		if run.DurationS != nil {
			totalDuration += *run.DurationS
			durationCount++
		}
		for _, tag := range run.Tags {
			tagCounts[tag]++
		}
	}

	if durationCount > 0 {
		stats.AvgDuration = float64(totalDuration) / float64(durationCount)
	}

	for tag, count := range tagCounts {
		stats.TopTags = append(stats.TopTags, TagCount{Tag: tag, Count: count})
	}
	// Sort by count descending
	for i := 0; i < len(stats.TopTags); i++ {
		for j := i + 1; j < len(stats.TopTags); j++ {
			if stats.TopTags[j].Count > stats.TopTags[i].Count {
				stats.TopTags[i], stats.TopTags[j] = stats.TopTags[j], stats.TopTags[i]
			}
		}
	}
	if len(stats.TopTags) > 10 {
		stats.TopTags = stats.TopTags[:10]
	}

	return stats, nil
}

func (a *Analyzer) generateInsights(patterns []*db.Pattern, stats Stats) []*db.Insight {
	var insights []*db.Insight

	for _, p := range patterns {
		if p.Frequency < 3 {
			continue // need enough data
		}

		confidence := 0.5
		if p.Frequency >= 10 {
			confidence = 0.9
		} else if p.Frequency >= 5 {
			confidence = 0.75
		}

		text := generateInsightText(p, stats)
		if text == "" {
			continue
		}

		insights = append(insights, &db.Insight{
			ID:          fmt.Sprintf("ins-%s-%d", p.Name, stats.TotalRuns),
			Text:        text,
			Confidence:  confidence,
			BasedOnRuns: stats.TotalRuns,
			Patterns:    []string{p.Name},
			Tags:        inferTags(p),
			Cadence:     "analysis",
			Active:      true,
		})
	}

	// Add overall success rate insight
	if stats.TotalRuns >= 5 {
		var text string
		if stats.SuccessRate >= 0.8 {
			text = fmt.Sprintf("Strong performance: %.0f%% success rate across %d runs. Keep doing what works.", stats.SuccessRate*100, stats.TotalRuns)
		} else if stats.SuccessRate < 0.5 {
			text = fmt.Sprintf("Low success rate: only %.0f%% across %d runs. Check the top failure patterns and address them systematically.", stats.SuccessRate*100, stats.TotalRuns)
		}
		if text != "" {
			insights = append(insights, &db.Insight{
				ID:          fmt.Sprintf("ins-overall-%d", stats.TotalRuns),
				Text:        text,
				Confidence:  0.85,
				BasedOnRuns: stats.TotalRuns,
				Cadence:     "analysis",
				Active:      true,
			})
		}
	}

	return insights
}

func generateInsightText(p *db.Pattern, stats Stats) string {
	pct := 0.0
	if stats.TotalRuns > 0 {
		pct = float64(p.Frequency) / float64(stats.TotalRuns) * 100
	}

	switch p.Name {
	case "tests-skipped":
		return fmt.Sprintf("Tests were skipped in %.0f%% of runs (%d times). Always run the test suite before declaring a task complete.", pct, p.Frequency)
	case "tests-failed":
		return fmt.Sprintf("Tests failed in %d runs (%.0f%% of all runs). Run tests early and often — don't wait until the end.", p.Frequency, pct)
	case "lint-failed":
		return fmt.Sprintf("Linter issues found in %d runs. Run the linter before committing to catch style and correctness issues early.", p.Frequency)
	case "scope-creep":
		return fmt.Sprintf("Scope creep detected in %d runs (%.0f%%). Stay focused on the specific task — resist refactoring unrelated code.", p.Frequency, pct)
	case "quick-failure":
		return fmt.Sprintf("Quick failures (under 60s) happened %d times. When a task fails immediately, read the error carefully before retrying.", p.Frequency)
	case "long-running":
		return fmt.Sprintf("Tasks ran over an hour %d times. If a task is taking too long, step back and reconsider the approach.", p.Frequency)
	case "no-test-files":
		return fmt.Sprintf("Source files were edited without touching tests in %d runs. Always update or add tests when modifying source code.", p.Frequency)
	case "success-with-errors":
		return fmt.Sprintf("Tasks were marked successful despite errors %d times. Investigate error messages even on 'successful' runs.", p.Frequency)
	default:
		return fmt.Sprintf("Pattern '%s' detected %d times (%.0f%%): %s", p.Name, p.Frequency, pct, p.Description)
	}
}

func inferTags(p *db.Pattern) []string {
	switch p.Category {
	case "process":
		return []string{"process", "workflow"}
	case "code":
		return []string{"code-quality", "testing"}
	case "scope":
		return []string{"scope", "efficiency"}
	default:
		return []string{p.Category}
	}
}
