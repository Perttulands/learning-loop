package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"

	"github.com/polis/learning-loop/internal/analyze"
	"github.com/polis/learning-loop/internal/db"
	"github.com/polis/learning-loop/internal/ingest"
	"github.com/polis/learning-loop/internal/query"
	"github.com/polis/learning-loop/internal/report"
)

var version = "0.1.0"

const defaultDBPath = ".learning-loop/loop.db"

func main() {
	root := &cobra.Command{
		Use:   "loop",
		Short: "Learning Loop — your agents get smarter with every run",
		Long: `Learning Loop captures what your AI agents do, learns what works,
and injects that knowledge into future runs.

  loop ingest <file>     Record an agent run
  loop query <task>      Get learnings for a task
  loop analyze           Extract patterns and insights
  loop status            See the big picture`,
		SilenceUsage: true,
	}

	root.PersistentFlags().String("db", "", "database path (default: .learning-loop/loop.db)")

	root.AddCommand(
		initCmd(),
		ingestCmd(),
		queryCmd(),
		analyzeCmd(),
		statusCmd(),
		patternsCmd(),
		insightsCmd(),
		runsCmd(),
		reportCmd(),
		versionCmd(),
	)

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

func openDB(cmd *cobra.Command) (*db.DB, error) {
	path, err := cmd.Flags().GetString("db")
	if err != nil {
		path = ""
	}
	if path == "" {
		path = defaultDBPath
	}
	return db.Open(path)
}

func flagBool(cmd *cobra.Command, name string) bool {
	v, err := cmd.Flags().GetBool(name)
	if err != nil {
		return false
	}
	return v
}

func flagInt(cmd *cobra.Command, name string, fallback int) int {
	v, err := cmd.Flags().GetInt(name)
	if err != nil {
		return fallback
	}
	return v
}

func flagString(cmd *cobra.Command, name string) string {
	v, err := cmd.Flags().GetString(name)
	if err != nil {
		return ""
	}
	return v
}

func initCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Initialize a new learning loop database",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return fmt.Errorf("init: %w", err)
			}
			defer d.Close()

			success := color.New(color.FgHiGreen, color.Bold)
			dim := color.New(color.FgHiBlack)

			fmt.Println()
			success.Println("  Learning Loop initialized")
			dim.Printf("  Database: %s\n", d.Path())
			fmt.Println()
			fmt.Println("  Next steps:")
			fmt.Println("    loop ingest <run.json>     Record your first agent run")
			fmt.Println("    loop query \"fix auth bug\"   Get learnings for a task")
			fmt.Println()
			return nil
		},
	}
}

func ingestCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ingest <file|->",
		Short: "Ingest a run record (file or stdin)",
		Long: `Record an agent run outcome. Pass a JSON file or use - for stdin.

Example:
  loop ingest run.json
  echo '{"id":"r1","task":"Fix bug","outcome":"success"}' | loop ingest -`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			var reader io.Reader
			if args[0] == "-" {
				reader = os.Stdin
			} else {
				f, err := os.Open(args[0])
				if err != nil {
					return fmt.Errorf("open file: %w", err)
				}
				defer f.Close()
				reader = f
			}

			ing := ingest.New(d)
			run, patterns, err := ing.IngestReader(reader)
			if err != nil {
				return err
			}

			success := color.New(color.FgHiGreen, color.Bold)
			dim := color.New(color.FgHiBlack)
			warn := color.New(color.FgHiYellow)

			fmt.Println()
			success.Fprintf(os.Stdout, "  Ingested")
			fmt.Printf(" %s", run.ID)
			dim.Printf(" [%s]", run.Outcome)
			fmt.Println()

			if len(patterns) > 0 {
				warn.Printf("  Patterns: ")
				fmt.Println(strings.Join(patterns, ", "))
			}
			fmt.Println()
			return nil
		},
	}
}

func queryCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "query <description>",
		Short: "Get learnings relevant to a task",
		Long: `Ask the learning loop what it knows about a type of task.

Example:
  loop query "fix authentication middleware"
  loop query "refactor database layer" --json
  loop query "add user registration" --inject >> .claude/context.md`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")
			inject := flagBool(cmd, "inject")
			maxRuns := flagInt(cmd, "max", 10)

			engine := query.New(d)
			result, err := engine.Query(args[0], maxRuns)
			if err != nil {
				return err
			}

			if asJSON {
				return result.WriteJSON(os.Stdout)
			}
			if inject {
				result.WriteInject(os.Stdout)
				return nil
			}
			result.WriteHuman(os.Stdout)
			return nil
		},
	}

	cmd.Flags().Bool("json", false, "output as JSON")
	cmd.Flags().Bool("inject", false, "output as injectable markdown context")
	cmd.Flags().Int("max", 10, "maximum relevant runs to consider")
	return cmd
}

func analyzeCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "analyze",
		Short: "Run analysis on new data",
		Long: `Analyze unprocessed runs to extract patterns and generate insights.

Run this after ingesting new data, or set up a cron job:
  */5 * * * * cd /project && loop analyze --json >> /var/log/loop.log`,
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")

			a := analyze.New(d)
			result, err := a.Analyze()
			if err != nil {
				return err
			}

			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(result)
			}

			success := color.New(color.FgHiGreen, color.Bold)
			dim := color.New(color.FgHiBlack)
			label := color.New(color.FgHiCyan, color.Bold)

			fmt.Println()
			if result.RunsAnalyzed == 0 {
				dim.Println("  No new runs to analyze.")
			} else {
				success.Fprintf(os.Stdout, "  Analyzed")
				fmt.Printf(" %d new runs\n", result.RunsAnalyzed)
			}

			if len(result.PatternsFound) > 0 {
				label.Printf("  Patterns: ")
				names := make([]string, 0, len(result.PatternsFound))
				for _, p := range result.PatternsFound {
					names = append(names, fmt.Sprintf("%s (%dx)", p.Name, p.Count))
				}
				fmt.Println(strings.Join(names, ", "))
			}

			if len(result.InsightsCreated) > 0 {
				label.Printf("  Insights: ")
				fmt.Printf("%d new\n", len(result.InsightsCreated))
			}

			if result.Stats.TotalRuns > 0 {
				rateColor := success
				if result.Stats.SuccessRate < 0.5 {
					rateColor = color.New(color.FgHiRed)
				} else if result.Stats.SuccessRate < 0.75 {
					rateColor = color.New(color.FgHiYellow)
				}
				label.Printf("  Overall:  ")
				rateColor.Printf("%.0f%%", result.Stats.SuccessRate*100)
				fmt.Printf(" success across %d runs\n", result.Stats.TotalRuns)
			}
			fmt.Println()
			return nil
		},
	}

	cmd.Flags().Bool("json", false, "output as JSON")
	return cmd
}

func statusCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Dashboard: runs, patterns, health",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")

			r := report.New(d)
			rpt, err := r.Generate()
			if err != nil {
				return err
			}

			if asJSON {
				return rpt.WriteJSON(os.Stdout)
			}
			rpt.WriteHuman(os.Stdout)
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "output as JSON")
	return cmd
}

func patternsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "patterns",
		Short: "List detected patterns with stats",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")

			patterns, err := d.ListPatterns()
			if err != nil {
				return err
			}

			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(patterns)
			}

			header := color.New(color.FgHiWhite, color.Bold)
			dim := color.New(color.FgHiBlack)
			warn := color.New(color.FgHiYellow)
			danger := color.New(color.FgHiRed)

			fmt.Println()
			if len(patterns) == 0 {
				dim.Println("  No patterns detected yet. Ingest some runs first.")
				fmt.Println()
				return nil
			}

			header.Println("  Detected Patterns")
			dim.Println("  ─────────────────")
			fmt.Println()

			for _, p := range patterns {
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
				impactColor.Fprintf(os.Stdout, "  ●")
				fmt.Fprintf(os.Stdout, " %-24s", p.Name)
				fmt.Fprintf(os.Stdout, " %3dx   ", p.Frequency)
				impactColor.Fprintf(os.Stdout, "%-6s", strings.ToUpper(p.Impact))
				dim.Fprintf(os.Stdout, "  %s", p.Description)
				fmt.Fprintln(os.Stdout)
			}
			fmt.Println()
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "output as JSON")
	return cmd
}

func insightsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "insights",
		Short: "Show actionable insights",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")
			tagsStr := flagString(cmd, "tags")

			var tags []string
			if tagsStr != "" {
				tags = strings.Split(tagsStr, ",")
			}

			insights, err := d.ListInsights(true, tags)
			if err != nil {
				return err
			}

			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(insights)
			}

			dim := color.New(color.FgHiBlack)
			header := color.New(color.FgHiWhite, color.Bold)

			fmt.Println()
			if len(insights) == 0 {
				dim.Println("  No insights yet. Run: loop analyze")
				fmt.Println()
				return nil
			}

			header.Println("  Active Insights")
			dim.Println("  ───────────────")
			fmt.Println()

			for i, ins := range insights {
				dim.Fprintf(os.Stdout, "  %d. ", i+1)
				fmt.Fprintf(os.Stdout, "%s", ins.Text)
				dim.Fprintf(os.Stdout, " (%.0f%%)", ins.Confidence*100)
				fmt.Fprintln(os.Stdout)
				if i < len(insights)-1 {
					fmt.Fprintln(os.Stdout)
				}
			}
			fmt.Println()
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "output as JSON")
	cmd.Flags().String("tags", "", "filter by tags (comma-separated)")
	return cmd
}

func runsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "runs",
		Short: "List recent runs with outcomes",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")
			last := flagInt(cmd, "last", 20)
			outcome := flagString(cmd, "outcome")

			runs, err := d.ListRuns(last, outcome)
			if err != nil {
				return err
			}

			if asJSON {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(runs)
			}

			dim := color.New(color.FgHiBlack)
			header := color.New(color.FgHiWhite, color.Bold)
			success := color.New(color.FgHiGreen)
			danger := color.New(color.FgHiRed)
			warn := color.New(color.FgHiYellow)

			fmt.Println()
			if len(runs) == 0 {
				dim.Println("  No runs yet. Start with: loop ingest <file>")
				fmt.Println()
				return nil
			}

			header.Println("  Recent Runs")
			dim.Println("  ───────────")
			fmt.Println()

			for _, r := range runs {
				outcomeColor := dim
				symbol := "○"
				switch r.Outcome {
				case "success":
					outcomeColor = success
					symbol = "✓"
				case "failure":
					outcomeColor = danger
					symbol = "✗"
				case "partial":
					outcomeColor = warn
					symbol = "◐"
				case "error":
					outcomeColor = danger
					symbol = "!"
				}

				outcomeColor.Fprintf(os.Stdout, "  %s", symbol)
				fmt.Fprintf(os.Stdout, " %-12s", r.ID)
				outcomeColor.Fprintf(os.Stdout, " %-8s", r.Outcome)

				// Duration
				if r.DurationS != nil {
					dim.Fprintf(os.Stdout, " %4ds", *r.DurationS)
				} else {
					dim.Fprintf(os.Stdout, "   ---")
				}

				fmt.Fprintf(os.Stdout, "  %s", truncate(r.Task, 50))
				fmt.Fprintln(os.Stdout)
			}
			fmt.Println()
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "output as JSON")
	cmd.Flags().Int("last", 20, "number of runs to show")
	cmd.Flags().String("outcome", "", "filter by outcome (success|failure|partial|error)")
	return cmd
}

func reportCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "report",
		Short: "Generate a summary report",
		RunE: func(cmd *cobra.Command, args []string) error {
			d, err := openDB(cmd)
			if err != nil {
				return err
			}
			defer d.Close()

			asJSON := flagBool(cmd, "json")

			r := report.New(d)
			rpt, err := r.Generate()
			if err != nil {
				return err
			}

			if asJSON {
				return rpt.WriteJSON(os.Stdout)
			}
			rpt.WriteHuman(os.Stdout)
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "output as JSON")
	return cmd
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version",
		Run: func(cmd *cobra.Command, args []string) {
			bold := color.New(color.FgHiWhite, color.Bold)
			dim := color.New(color.FgHiBlack)
			bold.Printf("loop")
			dim.Printf(" v%s\n", version)
		},
	}
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max-3] + "..."
}
