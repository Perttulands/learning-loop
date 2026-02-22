package db

import (
	"database/sql"
	"fmt"
)

type Pattern struct {
	ID                 string `json:"id"`
	Name               string `json:"name"`
	Description        string `json:"description"`
	Category           string `json:"category"`
	Impact             string `json:"impact"`
	OutcomeCorrelation string `json:"outcome_correlation,omitempty"`
	Frequency          int    `json:"frequency"`
	FirstSeen          string `json:"first_seen,omitempty"`
	LastSeen           string `json:"last_seen,omitempty"`
	CreatedAt          string `json:"created_at,omitempty"`
}

func (d *DB) UpsertPattern(p *Pattern) error {
	_, err := d.conn.Exec(`
		INSERT INTO patterns (id, name, description, category, impact, outcome_correlation, frequency, first_seen, last_seen)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
			frequency = frequency + excluded.frequency,
			last_seen = excluded.last_seen,
			description = excluded.description`,
		p.ID, p.Name, p.Description, p.Category, p.Impact,
		p.OutcomeCorrelation, p.Frequency, p.FirstSeen, p.LastSeen)
	if err != nil {
		return fmt.Errorf("upsert pattern: %w", err)
	}
	return nil
}

func (d *DB) GetPatternByName(name string) (*Pattern, error) {
	p := &Pattern{}
	var firstSeen, lastSeen sql.NullString
	err := d.conn.QueryRow(`SELECT id, name, description, category, impact,
		outcome_correlation, frequency, first_seen, last_seen, created_at
		FROM patterns WHERE name = ?`, name).
		Scan(&p.ID, &p.Name, &p.Description, &p.Category, &p.Impact,
			&p.OutcomeCorrelation, &p.Frequency, &firstSeen, &lastSeen, &p.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("get pattern: %w", err)
	}
	if firstSeen.Valid {
		p.FirstSeen = firstSeen.String
	}
	if lastSeen.Valid {
		p.LastSeen = lastSeen.String
	}
	return p, nil
}

func (d *DB) ListPatterns() ([]*Pattern, error) {
	rows, err := d.conn.Query(`SELECT id, name, description, category, impact,
		outcome_correlation, frequency, first_seen, last_seen, created_at
		FROM patterns ORDER BY frequency DESC`)
	if err != nil {
		return nil, fmt.Errorf("list patterns: %w", err)
	}
	defer rows.Close()

	var patterns []*Pattern
	for rows.Next() {
		p := &Pattern{}
		var firstSeen, lastSeen sql.NullString
		err := rows.Scan(&p.ID, &p.Name, &p.Description, &p.Category, &p.Impact,
			&p.OutcomeCorrelation, &p.Frequency, &firstSeen, &lastSeen, &p.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan pattern: %w", err)
		}
		if firstSeen.Valid {
			p.FirstSeen = firstSeen.String
		}
		if lastSeen.Valid {
			p.LastSeen = lastSeen.String
		}
		patterns = append(patterns, p)
	}
	return patterns, rows.Err()
}

func (d *DB) AddPatternMatch(runID, patternID string) error {
	_, err := d.conn.Exec(`
		INSERT OR IGNORE INTO pattern_matches (run_id, pattern_id) VALUES (?, ?)`,
		runID, patternID)
	return err
}

func (d *DB) GetPatternsForRun(runID string) ([]*Pattern, error) {
	rows, err := d.conn.Query(`
		SELECT p.id, p.name, p.description, p.category, p.impact,
			p.outcome_correlation, p.frequency, p.first_seen, p.last_seen, p.created_at
		FROM patterns p
		JOIN pattern_matches pm ON pm.pattern_id = p.id
		WHERE pm.run_id = ?
		ORDER BY p.frequency DESC`, runID)
	if err != nil {
		return nil, fmt.Errorf("get patterns for run: %w", err)
	}
	defer rows.Close()

	var patterns []*Pattern
	for rows.Next() {
		p := &Pattern{}
		var firstSeen, lastSeen sql.NullString
		err := rows.Scan(&p.ID, &p.Name, &p.Description, &p.Category, &p.Impact,
			&p.OutcomeCorrelation, &p.Frequency, &firstSeen, &lastSeen, &p.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan pattern: %w", err)
		}
		if firstSeen.Valid {
			p.FirstSeen = firstSeen.String
		}
		if lastSeen.Valid {
			p.LastSeen = lastSeen.String
		}
		patterns = append(patterns, p)
	}
	return patterns, rows.Err()
}
