package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
)

type Insight struct {
	ID          string   `json:"id"`
	Text        string   `json:"text"`
	Confidence  float64  `json:"confidence"`
	BasedOnRuns int      `json:"based_on_runs"`
	Patterns    []string `json:"patterns,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	Cadence     string   `json:"cadence"`
	Active      bool     `json:"active"`
	CreatedAt   string   `json:"created_at,omitempty"`
	ExpiresAt   string   `json:"expires_at,omitempty"`
}

func (d *DB) InsertInsight(i *Insight) error {
	patternsJSON, err := json.Marshal(ensureSlice(i.Patterns))
	if err != nil {
		return fmt.Errorf("marshal patterns: %w", err)
	}
	tagsJSON, err := json.Marshal(ensureSlice(i.Tags))
	if err != nil {
		return fmt.Errorf("marshal tags: %w", err)
	}

	active := 1
	if !i.Active {
		active = 0
	}

	var expiresAt *string
	if i.ExpiresAt != "" {
		expiresAt = &i.ExpiresAt
	}

	_, err = d.conn.Exec(`
		INSERT INTO insights (id, text, confidence, based_on_runs, patterns, tags, cadence, active, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		i.ID, i.Text, i.Confidence, i.BasedOnRuns,
		string(patternsJSON), string(tagsJSON), i.Cadence, active, expiresAt)
	if err != nil {
		return fmt.Errorf("insert insight: %w", err)
	}
	return nil
}

func (d *DB) ListInsights(activeOnly bool, tags []string) ([]*Insight, error) {
	q := `SELECT id, text, confidence, based_on_runs, patterns, tags, cadence, active, created_at, expires_at
		FROM insights`

	var conditions []string
	var args []any

	if activeOnly {
		conditions = append(conditions, "active = 1")
	}

	if len(conditions) > 0 {
		q += " WHERE " + conditions[0]
		for _, c := range conditions[1:] {
			q += " AND " + c
		}
	}
	q += " ORDER BY confidence DESC, created_at DESC"

	rows, err := d.conn.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list insights: %w", err)
	}
	defer rows.Close()

	var insights []*Insight
	for rows.Next() {
		i, err := scanInsightRow(rows)
		if err != nil {
			return nil, fmt.Errorf("list insights: %w", err)
		}
		// Tag filter in application layer for JSON array matching
		if len(tags) > 0 && !hasAnyTag(i.Tags, tags) {
			continue
		}
		insights = append(insights, i)
	}
	return insights, rows.Err()
}

func (d *DB) GetInsightsByTags(tags []string) ([]*Insight, error) {
	return d.ListInsights(true, tags)
}

func (d *DB) DeactivateInsight(id string) error {
	_, err := d.conn.Exec(`UPDATE insights SET active = 0 WHERE id = ?`, id)
	return err
}

func (d *DB) CountInsights() (int, error) {
	var count int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM insights WHERE active = 1`).Scan(&count)
	return count, err
}

func scanInsightRow(rows *sql.Rows) (*Insight, error) {
	i := &Insight{}
	var patternsJSON, tagsJSON string
	var active int
	var expiresAt sql.NullString

	err := rows.Scan(&i.ID, &i.Text, &i.Confidence, &i.BasedOnRuns,
		&patternsJSON, &tagsJSON, &i.Cadence, &active, &i.CreatedAt, &expiresAt)
	if err != nil {
		return nil, fmt.Errorf("scan insight: %w", err)
	}

	i.Active = active != 0
	if expiresAt.Valid {
		i.ExpiresAt = expiresAt.String
	}
	json.Unmarshal([]byte(patternsJSON), &i.Patterns)
	json.Unmarshal([]byte(tagsJSON), &i.Tags)
	return i, nil
}

func hasAnyTag(haystack, needles []string) bool {
	set := make(map[string]bool, len(haystack))
	for _, t := range haystack {
		set[t] = true
	}
	for _, n := range needles {
		if set[n] {
			return true
		}
	}
	return false
}
