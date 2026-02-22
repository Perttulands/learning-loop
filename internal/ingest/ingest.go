package ingest

import (
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/polis/learning-loop/internal/db"
)

type Ingester struct {
	db *db.DB
}

func New(database *db.DB) *Ingester {
	return &Ingester{db: database}
}

func (ing *Ingester) IngestReader(r io.Reader) (*db.Run, []string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, nil, fmt.Errorf("read input: %w", err)
	}
	return ing.IngestJSON(data)
}

func (ing *Ingester) IngestJSON(data []byte) (*db.Run, []string, error) {
	var run db.Run
	if err := json.Unmarshal(data, &run); err != nil {
		return nil, nil, fmt.Errorf("parse run record: %w", err)
	}

	if err := validateRun(&run); err != nil {
		return nil, nil, fmt.Errorf("validate run: %w", err)
	}

	exists, err := ing.db.RunExists(run.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("check run exists: %w", err)
	}
	if exists {
		return nil, nil, fmt.Errorf("run %q already ingested", run.ID)
	}

	if err := ing.db.InsertRun(&run); err != nil {
		return nil, nil, fmt.Errorf("store run: %w", err)
	}

	matched, err := detectAndStore(ing.db, &run)
	if err != nil {
		return &run, nil, fmt.Errorf("pattern detection: %w", err)
	}

	return &run, matched, nil
}

func validateRun(r *db.Run) error {
	if r.ID == "" {
		return fmt.Errorf("missing required field: id")
	}
	if r.Task == "" {
		return fmt.Errorf("missing required field: task")
	}
	if r.Outcome == "" {
		return fmt.Errorf("missing required field: outcome")
	}
	switch r.Outcome {
	case "success", "partial", "failure", "error":
	default:
		return fmt.Errorf("invalid outcome %q: must be success, partial, failure, or error", r.Outcome)
	}
	if r.Timestamp == "" {
		r.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}
	return nil
}
