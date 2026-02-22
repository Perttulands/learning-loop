package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var version = "0.1.0"

func main() {
	root := &cobra.Command{
		Use:   "loop",
		Short: "Learning Loop — closed-loop agent improvement system",
		Long:  "Ingest agent run outcomes, extract patterns, and answer: what should I know before starting this task?",
	}

	root.AddCommand(
		initCmd(),
		versionCmd(),
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func initCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Initialize a new learning loop database",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("Learning loop initialized.")
			return nil
		},
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("loop %s\n", version)
		},
	}
}
