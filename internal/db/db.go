package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

const defaultDBFile = ".learning-loop/loop.db"

type DB struct {
	conn *sql.DB
	path string
}

func Open(path string) (*DB, error) {
	if path == "" {
		path = defaultDBFile
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create db directory: %w", err)
	}

	conn, err := sql.Open("sqlite", path+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	conn.SetMaxOpenConns(1)

	d := &DB{conn: conn, path: path}
	if err := d.migrate(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return d, nil
}

func (d *DB) Close() error {
	return d.conn.Close()
}

func (d *DB) Path() string {
	return d.path
}

func (d *DB) Conn() *sql.DB {
	return d.conn
}

func (d *DB) migrate() error {
	_, err := d.conn.Exec(schema)
	return err
}

const schema = `
CREATE TABLE IF NOT EXISTS runs (
    id            TEXT PRIMARY KEY,
    task          TEXT NOT NULL,
    outcome       TEXT NOT NULL CHECK (outcome IN ('success','partial','failure','error')),
    duration_s    INTEGER,
    timestamp     TEXT NOT NULL,
    tools_used    TEXT DEFAULT '[]',
    files_touched TEXT DEFAULT '[]',
    tests_passed  INTEGER,
    lint_passed   INTEGER,
    error_message TEXT,
    tags          TEXT DEFAULT '[]',
    agent         TEXT DEFAULT '',
    model         TEXT DEFAULT '',
    metadata      TEXT DEFAULT '{}',
    analyzed      INTEGER DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS patterns (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL UNIQUE,
    description        TEXT NOT NULL,
    category           TEXT NOT NULL,
    impact             TEXT NOT NULL,
    outcome_correlation TEXT DEFAULT '',
    frequency          INTEGER DEFAULT 0,
    first_seen         TEXT,
    last_seen          TEXT,
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS pattern_matches (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     TEXT NOT NULL REFERENCES runs(id),
    pattern_id TEXT NOT NULL REFERENCES patterns(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(run_id, pattern_id)
);

CREATE TABLE IF NOT EXISTS insights (
    id            TEXT PRIMARY KEY,
    text          TEXT NOT NULL,
    confidence    REAL NOT NULL,
    based_on_runs INTEGER NOT NULL,
    patterns      TEXT DEFAULT '[]',
    tags          TEXT DEFAULT '[]',
    cadence       TEXT NOT NULL,
    active        INTEGER DEFAULT 1,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    expires_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_runs_outcome ON runs(outcome);
CREATE INDEX IF NOT EXISTS idx_runs_timestamp ON runs(timestamp);
CREATE INDEX IF NOT EXISTS idx_runs_analyzed ON runs(analyzed);
CREATE INDEX IF NOT EXISTS idx_patterns_name ON patterns(name);
CREATE INDEX IF NOT EXISTS idx_pattern_matches_run ON pattern_matches(run_id);
CREATE INDEX IF NOT EXISTS idx_pattern_matches_pattern ON pattern_matches(pattern_id);
CREATE INDEX IF NOT EXISTS idx_insights_active ON insights(active);
`
