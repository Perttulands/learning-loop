package report

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/fatih/color"
	"github.com/polis/learning-loop/internal/db"
)

type Reporter struct {
	db *db.DB
}

type Report struct {
	TotalRuns   int              `json:"total_runs"`
	SuccessRuns int              `json:"success_runs"`
	FailureRuns int              `json:"failure_runs"`
	SuccessRate float64          `json:"success_rate"`
	Patterns    []*db.Pattern    `json:"patterns"`
	Insights    []*db.Insight    `json:"insights"`
}

func New(database *db.DB) *Reporter {
	return &Reporter{db: database}
}

func (r *Reporter) Generate() (*Report, error) {
	total, success, failure, err := r.db.CountRuns()
	if err != nil {
		return nil, fmt.Errorf("count runs: %w", err)
	}

	patterns, err := r.db.ListPatterns()
	if err != nil {
		return nil, fmt.Errorf("list patterns: %w", err)
	}

	insights, err := r.db.ListInsights(true, nil)
	if err != nil {
		return nil, fmt.Errorf("list insights: %w", err)
	}

	successRate := 0.0
	if total > 0 {
		successRate = float64(success) / float64(total)
	}

	return &Report{
		TotalRuns:   total,
		SuccessRuns: success,
		FailureRuns: failure,
		SuccessRate: successRate,
		Patterns:    patterns,
		Insights:    insights,
	}, nil
}

func (rpt *Report) WriteJSON(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(rpt)
}

func (rpt *Report) WriteHuman(w io.Writer) {
	header := color.New(color.FgHiWhite, color.Bold)
	label := color.New(color.FgHiCyan, color.Bold)
	success := color.New(color.FgHiGreen)
	warn := color.New(color.FgHiYellow)
	danger := color.New(color.FgHiRed)
	dim := color.New(color.FgHiBlack)

	fmt.Fprintln(w)
	header.Fprintln(w, "  Learning Loop Report")
	dim.Fprintln(w, "  ─────────────────────")
	fmt.Fprintln(w)

	// Stats
	label.Fprintf(w, "  Runs: ")
	fmt.Fprintf(w, "%d total", rpt.TotalRuns)
	if rpt.TotalRuns > 0 {
		fmt.Fprintf(w, " (")
		success.Fprintf(w, "%d success", rpt.SuccessRuns)
		fmt.Fprintf(w, ", ")
		danger.Fprintf(w, "%d failure", rpt.FailureRuns)
		fmt.Fprintf(w, ", %d other", rpt.TotalRuns-rpt.SuccessRuns-rpt.FailureRuns)
		fmt.Fprintf(w, ")")
	}
	fmt.Fprintln(w)

	label.Fprintf(w, "  Rate: ")
	rateColor := success
	if rpt.SuccessRate < 0.5 {
		rateColor = danger
	} else if rpt.SuccessRate < 0.75 {
		rateColor = warn
	}
	rateColor.Fprintf(w, "%.0f%%", rpt.SuccessRate*100)
	fmt.Fprintln(w, " success")
	fmt.Fprintln(w)

	// Patterns
	if len(rpt.Patterns) > 0 {
		label.Fprintln(w, "  Patterns Detected")
		for _, p := range rpt.Patterns {
			if p.Frequency == 0 {
				continue
			}
			impactColor := dim
			switch p.Impact {
			case "high":
				impactColor = danger
			case "medium":
				impactColor = warn
			}
			fmt.Fprintf(w, "    ")
			impactColor.Fprintf(w, "●")
			fmt.Fprintf(w, " %-24s %3dx   ", p.Name, p.Frequency)
			impactColor.Fprintf(w, "%s", strings.ToUpper(p.Impact))
			fmt.Fprintln(w)
		}
		fmt.Fprintln(w)
	}

	// Insights
	if len(rpt.Insights) > 0 {
		label.Fprintln(w, "  Active Insights")
		for i, ins := range rpt.Insights {
			dim.Fprintf(w, "    %d. ", i+1)
			fmt.Fprintf(w, "%s", ins.Text)
			dim.Fprintf(w, " (%.0f%% confidence)", ins.Confidence*100)
			fmt.Fprintln(w)
		}
		fmt.Fprintln(w)
	}

	if rpt.TotalRuns == 0 {
		dim.Fprintln(w, "  No data yet. Start with: loop ingest <file>")
		fmt.Fprintln(w)
	}
}
