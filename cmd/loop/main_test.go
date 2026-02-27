package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

// ── helpers ────────────────────────────────────────────────

// executeCmd runs a cobra command tree with the given args and returns
// combined stdout+stderr and any error.
func executeCmd(root *cobra.Command, args ...string) (string, error) {
	buf := new(bytes.Buffer)
	root.SetOut(buf)
	root.SetErr(buf)
	root.SetArgs(args)
	err := root.Execute()
	return buf.String(), err
}

// buildRoot mirrors main() but returns the command instead of executing it.
func buildRoot() *cobra.Command {
	root := &cobra.Command{
		Use:          "loop",
		Short:        "Learning Loop — your agents get smarter with every run",
		SilenceUsage: true,
	}
	root.PersistentFlags().String("db", "", "database path")
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
	return root
}

// ── command routing ────────────────────────────────────────

func TestCommandRouting_UnknownSubcommand(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "nonexistent")
	if err == nil {
		t.Fatal("expected error for unknown subcommand")
	}
}

func TestCommandRouting_VersionRuns(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "version")
	if err != nil {
		t.Fatalf("version command should succeed: %v", err)
	}
}

func TestCommandRouting_HelpListsSubcommands(t *testing.T) {
	root := buildRoot()
	out, err := executeCmd(root, "--help")
	if err != nil {
		t.Fatalf("help should succeed: %v", err)
	}
	for _, sub := range []string{"init", "ingest", "query", "analyze", "status", "patterns", "insights", "runs", "report", "version"} {
		if !strings.Contains(out, sub) {
			t.Errorf("help output should list %q subcommand", sub)
		}
	}
}

// ── missing args (ExactArgs enforcement) ───────────────────

func TestIngest_ErrorOnMissingArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "ingest")
	if err == nil {
		t.Fatal("ingest with no args should fail")
	}
	if !strings.Contains(err.Error(), "accepts 1 arg") {
		t.Fatalf("expected ExactArgs error, got: %v", err)
	}
}

func TestIngest_ErrorOnTooManyArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "ingest", "a", "b")
	if err == nil {
		t.Fatal("ingest with 2 args should fail")
	}
}

func TestQuery_ErrorOnMissingArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "query")
	if err == nil {
		t.Fatal("query with no args should fail")
	}
	if !strings.Contains(err.Error(), "accepts 1 arg") {
		t.Fatalf("expected ExactArgs error, got: %v", err)
	}
}

func TestQuery_ErrorOnTooManyArgs(t *testing.T) {
	root := buildRoot()
	_, err := executeCmd(root, "query", "a", "b")
	if err == nil {
		t.Fatal("query with 2 args should fail")
	}
}

// ── flag parsing ───────────────────────────────────────────

func TestQueryFlags_Registered(t *testing.T) {
	cmd := queryCmd()
	for _, flag := range []string{"json", "inject", "max"} {
		if cmd.Flags().Lookup(flag) == nil {
			t.Errorf("query command should have --%s flag", flag)
		}
	}
}

func TestRunsFlags_Registered(t *testing.T) {
	cmd := runsCmd()
	for _, flag := range []string{"json", "last", "outcome"} {
		if cmd.Flags().Lookup(flag) == nil {
			t.Errorf("runs command should have --%s flag", flag)
		}
	}
}

func TestInsightsFlags_Registered(t *testing.T) {
	cmd := insightsCmd()
	for _, flag := range []string{"json", "tags"} {
		if cmd.Flags().Lookup(flag) == nil {
			t.Errorf("insights command should have --%s flag", flag)
		}
	}
}

func TestPersistentDBFlag(t *testing.T) {
	root := buildRoot()
	f := root.PersistentFlags().Lookup("db")
	if f == nil {
		t.Fatal("root command should have persistent --db flag")
	}
}

// ── flag helper functions ──────────────────────────────────

func TestFlagBool_DefaultFalse(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().Bool("test", false, "")
	if flagBool(cmd, "test") {
		t.Fatal("expected default false")
	}
}

func TestFlagBool_SetTrue(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().Bool("test", false, "")
	_ = cmd.Flags().Set("test", "true")
	if !flagBool(cmd, "test") {
		t.Fatal("expected true after set")
	}
}

func TestFlagBool_MissingFlag(t *testing.T) {
	cmd := &cobra.Command{}
	// no flag registered — should return false, not panic
	if flagBool(cmd, "missing") {
		t.Fatal("expected false for missing flag")
	}
}

func TestFlagInt_Default(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().Int("n", 42, "")
	if got := flagInt(cmd, "n", 99); got != 42 {
		t.Fatalf("expected 42, got %d", got)
	}
}

func TestFlagInt_Fallback(t *testing.T) {
	cmd := &cobra.Command{}
	// no flag registered — should return fallback
	if got := flagInt(cmd, "missing", 99); got != 99 {
		t.Fatalf("expected fallback 99, got %d", got)
	}
}

func TestFlagString_Default(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().String("name", "hello", "")
	if got := flagString(cmd, "name"); got != "hello" {
		t.Fatalf("expected hello, got %q", got)
	}
}

func TestFlagString_MissingFlag(t *testing.T) {
	cmd := &cobra.Command{}
	if got := flagString(cmd, "missing"); got != "" {
		t.Fatalf("expected empty string for missing flag, got %q", got)
	}
}

// ── truncate helper ────────────────────────────────────────

func TestTruncate_Short(t *testing.T) {
	if got := truncate("hello", 10); got != "hello" {
		t.Fatalf("expected hello, got %q", got)
	}
}

func TestTruncate_Exact(t *testing.T) {
	if got := truncate("hello", 5); got != "hello" {
		t.Fatalf("expected hello, got %q", got)
	}
}

func TestTruncate_Long(t *testing.T) {
	got := truncate("hello world", 8)
	if got != "hello..." {
		t.Fatalf("expected hello..., got %q", got)
	}
}
