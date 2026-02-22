package query

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/fatih/color"
	"github.com/polis/learning-loop/internal/db"
)

type Engine struct {
	db *db.DB
}

type Result struct {
	Query         string        `json:"query"`
	TotalRuns     int           `json:"total_runs"`
	MatchedRuns   int           `json:"matched_runs"`
	SuccessRate   float64       `json:"success_rate"`
	Insights      []*db.Insight `json:"insights"`
	TopPatterns   []PatternStat `json:"top_patterns"`
	SuccessSignals []string     `json:"success_signals"`
	RelevantRuns  []*db.Run     `json:"relevant_runs,omitempty"`
}

type PatternStat struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Count       int    `json:"count"`
	Impact      string `json:"impact"`
}

func New(database *db.DB) *Engine {
	return &Engine{db: database}
}

func (e *Engine) Query(description string, maxRuns int) (*Result, error) {
	if maxRuns <= 0 {
		maxRuns = 10
	}

	keywords := extractKeywords(description)
	now := time.Now().UTC()

	allRuns, err := e.db.ListRuns(0, "")
	if err != nil {
		return nil, fmt.Errorf("list runs: %w", err)
	}

	// Score and rank runs
	var scored []ScoredRun
	for _, run := range allRuns {
		s := scoreRun(run, keywords, now)
		if s > 0.5 { // minimum relevance threshold
			scored = append(scored, ScoredRun{Run: run, Score: s})
		}
	}

	sort.Slice(scored, func(i, j int) bool {
		return scored[i].Score > scored[j].Score
	})

	if len(scored) > maxRuns {
		scored = scored[:maxRuns]
	}

	// Compute stats from matched runs
	var successes, failures int
	for _, sr := range scored {
		switch sr.Run.Outcome {
		case "success":
			successes++
		case "failure":
			failures++
		}
	}

	successRate := 0.0
	if len(scored) > 0 {
		successRate = float64(successes) / float64(len(scored))
	}

	// Get patterns for matched runs
	patternCounts := make(map[string]*PatternStat)
	for _, sr := range scored {
		patterns, err := e.db.GetPatternsForRun(sr.Run.ID)
		if err != nil {
			continue
		}
		for _, p := range patterns {
			if ps, ok := patternCounts[p.Name]; ok {
				ps.Count++
			} else {
				patternCounts[p.Name] = &PatternStat{
					Name:        p.Name,
					Description: p.Description,
					Count:       1,
					Impact:      p.Impact,
				}
			}
		}
	}

	var topPatterns []PatternStat
	for _, ps := range patternCounts {
		topPatterns = append(topPatterns, *ps)
	}
	sort.Slice(topPatterns, func(i, j int) bool {
		return topPatterns[i].Count > topPatterns[j].Count
	})
	if len(topPatterns) > 5 {
		topPatterns = topPatterns[:5]
	}

	// Get relevant insights
	insights, err := e.db.ListInsights(true, keywords)
	if err != nil {
		insights = nil // non-fatal
	}
	// Also try without keyword filter if none matched
	if len(insights) == 0 {
		allInsights, insErr := e.db.ListInsights(true, nil)
		if insErr == nil {
			insights = allInsights
		}
	}
	if len(insights) > 5 {
		insights = insights[:5]
	}

	// Derive success signals from successful runs
	signals := deriveSuccessSignals(scored)

	var relevantRuns []*db.Run
	for _, sr := range scored {
		relevantRuns = append(relevantRuns, sr.Run)
	}

	return &Result{
		Query:          description,
		TotalRuns:      len(allRuns),
		MatchedRuns:    len(scored),
		SuccessRate:    successRate,
		Insights:       insights,
		TopPatterns:    topPatterns,
		SuccessSignals: signals,
		RelevantRuns:   relevantRuns,
	}, nil
}

func deriveSuccessSignals(scored []ScoredRun) []string {
	if len(scored) == 0 {
		return nil
	}

	var signals []string

	// Check: runs with test files alongside source
	withTests, withTestsSuccess := 0, 0
	for _, sr := range scored {
		hasTestFile := false
		for _, f := range sr.Run.FilesTouched {
			lower := strings.ToLower(f)
			if strings.Contains(lower, "test") {
				hasTestFile = true
				break
			}
		}
		if hasTestFile {
			withTests++
			if sr.Run.Outcome == "success" {
				withTestsSuccess++
			}
		}
	}
	if withTests >= 3 {
		rate := float64(withTestsSuccess) / float64(withTests) * 100
		if rate > 70 {
			signals = append(signals, fmt.Sprintf("Edited test files alongside source → %.0f%% success rate", rate))
		}
	}

	// Check: short duration correlation
	shortRuns, shortSuccess := 0, 0
	for _, sr := range scored {
		if sr.Run.DurationS != nil && *sr.Run.DurationS < 600 {
			shortRuns++
			if sr.Run.Outcome == "success" {
				shortSuccess++
			}
		}
	}
	if shortRuns >= 3 {
		rate := float64(shortSuccess) / float64(shortRuns) * 100
		if rate > 70 {
			signals = append(signals, fmt.Sprintf("Completed in under 10 minutes → %.0f%% success rate", rate))
		}
	}

	// Check: tests passed correlation
	testsPassed, testsPassedSuccess := 0, 0
	for _, sr := range scored {
		if sr.Run.TestsPassed != nil && *sr.Run.TestsPassed {
			testsPassed++
			if sr.Run.Outcome == "success" {
				testsPassedSuccess++
			}
		}
	}
	if testsPassed >= 3 {
		rate := float64(testsPassedSuccess) / float64(testsPassed) * 100
		if rate > 70 {
			signals = append(signals, fmt.Sprintf("Ran tests and they passed → %.0f%% success rate", rate))
		}
	}

	return signals
}

func (r *Result) WriteJSON(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(r)
}

func (r *Result) WriteHuman(w io.Writer) {
	header := color.New(color.FgHiWhite, color.Bold)
	label := color.New(color.FgHiCyan, color.Bold)
	dim := color.New(color.FgHiBlack)
	success := color.New(color.FgHiGreen)
	warn := color.New(color.FgHiYellow)
	danger := color.New(color.FgHiRed)

	fmt.Fprintln(w)

	if r.MatchedRuns == 0 && len(r.Insights) == 0 {
		dim.Fprintf(w, "  No relevant learnings found for: %q\n", r.Query)
		dim.Fprintf(w, "  Ingest more runs with: loop ingest <file>\n\n")
		return
	}

	// Header with stats
	label.Fprintf(w, " LEARNINGS ")
	header.Fprintf(w, " From %d", r.MatchedRuns)
	if r.MatchedRuns != r.TotalRuns {
		dim.Fprintf(w, "/%d", r.TotalRuns)
	}
	header.Fprintf(w, " runs")
	if r.MatchedRuns > 0 {
		rateColor := success
		if r.SuccessRate < 0.5 {
			rateColor = danger
		} else if r.SuccessRate < 0.75 {
			rateColor = warn
		}
		fmt.Fprintf(w, " (")
		rateColor.Fprintf(w, "%.0f%% success", r.SuccessRate*100)
		fmt.Fprintf(w, ")")
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w)

	// Insights
	if len(r.Insights) > 0 {
		for i, ins := range r.Insights {
			dim.Fprintf(w, "  %d. ", i+1)
			fmt.Fprintf(w, "%s\n", ins.Text)
			if i < len(r.Insights)-1 {
				fmt.Fprintln(w)
			}
		}
		fmt.Fprintln(w)
	}

	// Patterns
	if len(r.TopPatterns) > 0 {
		label.Fprintf(w, " WATCH OUT ")
		header.Fprintf(w, " Patterns that caused failures\n")
		fmt.Fprintln(w)
		for _, p := range r.TopPatterns {
			impactColor := dim
			switch p.Impact {
			case "high":
				impactColor = danger
			case "medium":
				impactColor = warn
			}
			fmt.Fprintf(w, "  ")
			danger.Fprintf(w, "●")
			fmt.Fprintf(w, " %-24s %2d occurrences   ", p.Name, p.Count)
			impactColor.Fprintf(w, "%s", strings.ToUpper(p.Impact))
			fmt.Fprintf(w, " impact\n")
		}
		fmt.Fprintln(w)
	}

	// Success signals
	if len(r.SuccessSignals) > 0 {
		label.Fprintf(w, " SUCCESS SIGNALS ")
		header.Fprintf(w, " What winning runs looked like\n")
		fmt.Fprintln(w)
		for _, sig := range r.SuccessSignals {
			fmt.Fprintf(w, "  ")
			success.Fprintf(w, "✓")
			fmt.Fprintf(w, " %s\n", sig)
		}
		fmt.Fprintln(w)
	}
}

func (r *Result) WriteInject(w io.Writer) {
	fmt.Fprintf(w, "## Learnings for: %q\n\n", r.Query)

	if r.MatchedRuns == 0 && len(r.Insights) == 0 {
		fmt.Fprintln(w, "No relevant learnings found yet.")
		return
	}

	if r.MatchedRuns > 0 {
		fmt.Fprintf(w, "**From %d similar runs (%.0f%% success rate):**\n\n", r.MatchedRuns, r.SuccessRate*100)
	}

	for i, ins := range r.Insights {
		fmt.Fprintf(w, "%d. %s\n\n", i+1, ins.Text)
	}

	if len(r.TopPatterns) > 0 {
		fmt.Fprintln(w, "**Common failure patterns in similar tasks:**")
		for _, p := range r.TopPatterns {
			fmt.Fprintf(w, "- %s (%d occurrences, %s impact)\n", p.Name, p.Count, p.Impact)
		}
		fmt.Fprintln(w)
	}

	if len(r.SuccessSignals) > 0 {
		fmt.Fprintln(w, "**Success patterns:**")
		for _, sig := range r.SuccessSignals {
			fmt.Fprintf(w, "- %s\n", sig)
		}
		fmt.Fprintln(w)
	}
}
