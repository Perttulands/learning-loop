package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
)

type Run struct {
	ID           string   `json:"id"`
	Task         string   `json:"task"`
	Outcome      string   `json:"outcome"`
	DurationS    *int     `json:"duration_seconds,omitempty"`
	Timestamp    string   `json:"timestamp"`
	ToolsUsed    []string `json:"tools_used,omitempty"`
	FilesTouched []string `json:"files_touched,omitempty"`
	TestsPassed  *bool    `json:"tests_passed,omitempty"`
	LintPassed   *bool    `json:"lint_passed,omitempty"`
	ErrorMessage string   `json:"error_message,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	Agent        string   `json:"agent,omitempty"`
	Model        string   `json:"model,omitempty"`
	Metadata     any      `json:"metadata,omitempty"`
	Analyzed     bool     `json:"-"`
	CreatedAt    string   `json:"created_at,omitempty"`
}

func (d *DB) InsertRun(r *Run) error {
	toolsJSON, err := json.Marshal(ensureSlice(r.ToolsUsed))
	if err != nil {
		return fmt.Errorf("marshal tools_used: %w", err)
	}
	filesJSON, err := json.Marshal(ensureSlice(r.FilesTouched))
	if err != nil {
		return fmt.Errorf("marshal files_touched: %w", err)
	}
	tagsJSON, err := json.Marshal(ensureSlice(r.Tags))
	if err != nil {
		return fmt.Errorf("marshal tags: %w", err)
	}
	metaJSON, err := json.Marshal(ensureMap(r.Metadata))
	if err != nil {
		return fmt.Errorf("marshal metadata: %w", err)
	}

	var testsPassed, lintPassed *int
	if r.TestsPassed != nil {
		v := boolToInt(*r.TestsPassed)
		testsPassed = &v
	}
	if r.LintPassed != nil {
		v := boolToInt(*r.LintPassed)
		lintPassed = &v
	}

	_, err = d.conn.Exec(`
		INSERT INTO runs (id, task, outcome, duration_s, timestamp, tools_used, files_touched,
		                   tests_passed, lint_passed, error_message, tags, agent, model, metadata)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Task, r.Outcome, r.DurationS, r.Timestamp,
		string(toolsJSON), string(filesJSON),
		testsPassed, lintPassed, r.ErrorMessage,
		string(tagsJSON), r.Agent, r.Model, string(metaJSON),
	)
	if err != nil {
		return fmt.Errorf("insert run: %w", err)
	}
	return nil
}

func (d *DB) GetRun(id string) (*Run, error) {
	row := d.conn.QueryRow(`SELECT id, task, outcome, duration_s, timestamp,
		tools_used, files_touched, tests_passed, lint_passed, error_message,
		tags, agent, model, metadata, analyzed, created_at FROM runs WHERE id = ?`, id)
	return scanRun(row)
}

func (d *DB) ListRuns(limit int, outcome string) ([]*Run, error) {
	q := `SELECT id, task, outcome, duration_s, timestamp,
		tools_used, files_touched, tests_passed, lint_passed, error_message,
		tags, agent, model, metadata, analyzed, created_at FROM runs`
	var args []any

	if outcome != "" {
		q += " WHERE outcome = ?"
		args = append(args, outcome)
	}
	q += " ORDER BY timestamp DESC"
	if limit > 0 {
		q += " LIMIT ?"
		args = append(args, limit)
	}

	rows, err := d.conn.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list runs: %w", err)
	}
	defer rows.Close()

	var runs []*Run
	for rows.Next() {
		r, err := scanRunRows(rows)
		if err != nil {
			return nil, fmt.Errorf("list runs: %w", err)
		}
		runs = append(runs, r)
	}
	return runs, rows.Err()
}

func (d *DB) GetUnanalyzedRuns() ([]*Run, error) {
	rows, err := d.conn.Query(`SELECT id, task, outcome, duration_s, timestamp,
		tools_used, files_touched, tests_passed, lint_passed, error_message,
		tags, agent, model, metadata, analyzed, created_at FROM runs
		WHERE analyzed = 0 ORDER BY timestamp ASC`)
	if err != nil {
		return nil, fmt.Errorf("get unanalyzed runs: %w", err)
	}
	defer rows.Close()

	var runs []*Run
	for rows.Next() {
		r, err := scanRunRows(rows)
		if err != nil {
			return nil, fmt.Errorf("get unanalyzed runs: %w", err)
		}
		runs = append(runs, r)
	}
	return runs, rows.Err()
}

func (d *DB) MarkRunAnalyzed(id string) error {
	_, err := d.conn.Exec(`UPDATE runs SET analyzed = 1 WHERE id = ?`, id)
	return err
}

func (d *DB) CountRuns() (total, success, failure int, err error) {
	if err = d.conn.QueryRow(`SELECT COUNT(*) FROM runs`).Scan(&total); err != nil {
		return 0, 0, 0, fmt.Errorf("count total runs: %w", err)
	}
	if err = d.conn.QueryRow(`SELECT COUNT(*) FROM runs WHERE outcome = 'success'`).Scan(&success); err != nil {
		return 0, 0, 0, fmt.Errorf("count success runs: %w", err)
	}
	if err = d.conn.QueryRow(`SELECT COUNT(*) FROM runs WHERE outcome = 'failure'`).Scan(&failure); err != nil {
		return 0, 0, 0, fmt.Errorf("count failure runs: %w", err)
	}
	return total, success, failure, nil
}

func (d *DB) RunExists(id string) (bool, error) {
	var count int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM runs WHERE id = ?`, id).Scan(&count)
	return count > 0, err
}

type scanner interface {
	Scan(dest ...any) error
}

func scanRun(row *sql.Row) (*Run, error) {
	r := &Run{}
	var durS sql.NullInt64
	var testsPassed, lintPassed sql.NullInt64
	var toolsJSON, filesJSON, tagsJSON, metaJSON string
	var analyzed int

	err := row.Scan(&r.ID, &r.Task, &r.Outcome, &durS, &r.Timestamp,
		&toolsJSON, &filesJSON, &testsPassed, &lintPassed, &r.ErrorMessage,
		&tagsJSON, &r.Agent, &r.Model, &metaJSON, &analyzed, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("scan run: %w", err)
	}

	populateRun(r, durS, testsPassed, lintPassed, toolsJSON, filesJSON, tagsJSON, metaJSON, analyzed)
	return r, nil
}

func scanRunRows(rows *sql.Rows) (*Run, error) {
	r := &Run{}
	var durS sql.NullInt64
	var testsPassed, lintPassed sql.NullInt64
	var toolsJSON, filesJSON, tagsJSON, metaJSON string
	var analyzed int

	err := rows.Scan(&r.ID, &r.Task, &r.Outcome, &durS, &r.Timestamp,
		&toolsJSON, &filesJSON, &testsPassed, &lintPassed, &r.ErrorMessage,
		&tagsJSON, &r.Agent, &r.Model, &metaJSON, &analyzed, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("scan run: %w", err)
	}

	populateRun(r, durS, testsPassed, lintPassed, toolsJSON, filesJSON, tagsJSON, metaJSON, analyzed)
	return r, nil
}

func populateRun(r *Run, durS, testsPassed, lintPassed sql.NullInt64,
	toolsJSON, filesJSON, tagsJSON, metaJSON string, analyzed int) {
	if durS.Valid {
		v := int(durS.Int64)
		r.DurationS = &v
	}
	if testsPassed.Valid {
		v := testsPassed.Int64 != 0
		r.TestsPassed = &v
	}
	if lintPassed.Valid {
		v := lintPassed.Int64 != 0
		r.LintPassed = &v
	}
	json.Unmarshal([]byte(toolsJSON), &r.ToolsUsed)
	json.Unmarshal([]byte(filesJSON), &r.FilesTouched)
	json.Unmarshal([]byte(tagsJSON), &r.Tags)
	json.Unmarshal([]byte(metaJSON), &r.Metadata)
	r.Analyzed = analyzed != 0
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func ensureSlice(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func ensureMap(v any) any {
	if v == nil {
		return map[string]any{}
	}
	return v
}
