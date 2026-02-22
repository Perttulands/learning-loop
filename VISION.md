# Learning Loop — Vision

## One-Sentence

A single Go binary that ingests agent run outcomes, extracts patterns, and answers the question: **"What should I know before starting this task?"**

## Architecture

```
                          ┌─────────────────────────────────────┐
                          │          learning-loop CLI          │
                          │                                     │
  Agent finishes ────────►│  loop ingest <run.json>             │
                          │    ├─ parse run record              │
                          │    ├─ detect patterns               │
                          │    ├─ store in SQLite               │
                          │    └─ trigger analysis (if needed)  │
                          │                                     │
  Agent starting ────────►│  loop query "fix auth middleware"   │
                          │    ├─ match relevant runs           │
                          │    ├─ retrieve patterns + insights  │
                          │    └─ emit injectable text block    │
                          │                                     │
  Human/cron ────────────►│  loop analyze [--cadence daily]     │
                          │    ├─ aggregate recent runs         │
                          │    ├─ cluster failures              │
                          │    ├─ generate insights             │
                          │    └─ update pattern registry       │
                          │                                     │
  Human ─────────────────►│  loop status                        │
                          │  loop patterns                      │
                          │  loop insights                      │
                          │  loop runs [--last 10]              │
                          │  loop report [--weekly]             │
                          └──────────────┬──────────────────────┘
                                         │
                                         ▼
                              ┌──────────────────┐
                              │   SQLite (embed)  │
                              │                   │
                              │  runs             │
                              │  patterns         │
                              │  insights         │
                              │  pattern_matches  │
                              └──────────────────┘
```

## Core Concepts

### Run Record (input)

What an agent tells us after it finishes. Minimal required fields, everything else optional.

```json
{
  "id": "run-a8f3e",
  "task": "Fix authentication bug in login middleware",
  "outcome": "success|partial|failure|error",
  "duration_seconds": 342,
  "timestamp": "2026-02-22T14:30:00Z",

  "tools_used": ["read", "edit", "bash", "grep"],
  "files_touched": ["src/auth/middleware.go", "src/auth/middleware_test.go"],
  "tests_passed": true,
  "lint_passed": true,
  "error_message": null,

  "tags": ["auth", "bug-fix", "middleware"],
  "agent": "claude-code",
  "model": "claude-opus-4-6",
  "metadata": {}
}
```

### Pattern (derived)

A recurring behavior extracted from multiple runs.

```json
{
  "id": "pat-001",
  "name": "tests-skipped-on-completion",
  "description": "Agent declares task complete without running tests",
  "frequency": 12,
  "impact": "high",
  "first_seen": "2026-02-15T10:00:00Z",
  "last_seen": "2026-02-22T14:30:00Z",
  "category": "process",
  "outcome_correlation": "failure"
}
```

### Insight (derived, human-readable)

An actionable recommendation generated from patterns and run data.

```json
{
  "id": "ins-001",
  "text": "When fixing auth-related bugs, always run the full test suite before committing. 34% of auth bug fixes failed because tests were skipped.",
  "confidence": 0.85,
  "based_on_runs": 23,
  "patterns": ["tests-skipped-on-completion"],
  "tags": ["auth", "testing"],
  "created_at": "2026-02-22T03:00:00Z",
  "cadence": "daily"
}
```

### Query Result (output)

What an agent receives when it asks for context. This is **the product**.

```
## Learnings for: "Fix authentication bug in login middleware"

**From 23 similar runs (78% success rate):**

1. Always run the full test suite before committing. 34% of auth bug fixes
   failed because tests were skipped.

2. Check the middleware chain order — auth middleware must run before
   rate limiting. 3 failures traced to incorrect ordering.

3. Auth-related changes tend to touch 2-4 files. If you're editing more
   than 5, you may be scope-creeping.

**Common failure patterns in similar tasks:**
- tests-skipped-on-completion (12 occurrences)
- scope-creep (4 occurrences)

**Success patterns:**
- Runs that edited test files alongside source files: 92% success rate
- Runs under 10 minutes: 85% success rate
```

## CLI Surface

```
loop ingest <file>              Ingest a run record (JSON file or stdin)
loop ingest --stdin             Read run record from stdin
loop query <description>        Get learnings relevant to a task description
loop query --tags auth,testing  Filter by tags
loop query --json               Output as JSON instead of text
loop analyze                    Run analysis on un-analyzed runs
loop analyze --cadence hourly   Run hourly-level analysis
loop analyze --cadence daily    Run daily-level analysis
loop analyze --cadence weekly   Run weekly-level analysis
loop patterns                   List all known patterns
loop patterns --active          Show only active (recent) patterns
loop insights                   List all insights
loop insights --tags auth       Filter by tag
loop runs                       List recent runs
loop runs --last 20             Show last N runs
loop runs --outcome failure     Filter by outcome
loop status                     System health: run count, pattern count, etc.
loop report                     Generate a summary report
loop report --weekly            Weekly cadence report
loop init                       Initialize a new learning loop database
loop version                    Print version
```

## SQLite Schema

```sql
CREATE TABLE runs (
    id          TEXT PRIMARY KEY,
    task        TEXT NOT NULL,
    outcome     TEXT NOT NULL CHECK (outcome IN ('success','partial','failure','error')),
    duration_s  INTEGER,
    timestamp   TEXT NOT NULL,
    tools_used  TEXT,           -- JSON array
    files_touched TEXT,         -- JSON array
    tests_passed INTEGER,      -- 0/1/NULL
    lint_passed  INTEGER,      -- 0/1/NULL
    error_message TEXT,
    tags        TEXT,           -- JSON array
    agent       TEXT,
    model       TEXT,
    metadata    TEXT,           -- JSON object
    analyzed    INTEGER DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE patterns (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    category    TEXT NOT NULL,     -- process, code, infrastructure, scope
    impact      TEXT NOT NULL,     -- high, medium, low
    outcome_correlation TEXT,      -- success, failure, partial
    frequency   INTEGER DEFAULT 0,
    first_seen  TEXT,
    last_seen   TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE pattern_matches (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      TEXT NOT NULL REFERENCES runs(id),
    pattern_id  TEXT NOT NULL REFERENCES patterns(id),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(run_id, pattern_id)
);

CREATE TABLE insights (
    id          TEXT PRIMARY KEY,
    text        TEXT NOT NULL,
    confidence  REAL NOT NULL,
    based_on_runs INTEGER NOT NULL,
    patterns    TEXT,              -- JSON array of pattern IDs
    tags        TEXT,              -- JSON array
    cadence     TEXT NOT NULL,     -- run, hourly, daily, weekly
    active      INTEGER DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    expires_at  TEXT
);

-- Indexes for query performance
CREATE INDEX idx_runs_outcome ON runs(outcome);
CREATE INDEX idx_runs_timestamp ON runs(timestamp);
CREATE INDEX idx_runs_analyzed ON runs(analyzed);
CREATE INDEX idx_runs_tags ON runs(tags);
CREATE INDEX idx_patterns_name ON patterns(name);
CREATE INDEX idx_pattern_matches_run ON pattern_matches(run_id);
CREATE INDEX idx_pattern_matches_pattern ON pattern_matches(pattern_id);
CREATE INDEX idx_insights_active ON insights(active);
CREATE INDEX idx_insights_tags ON insights(tags);
```

## Pattern Detection (Built-in)

These patterns are detected automatically on ingest:

| Pattern | Trigger | Category |
|---------|---------|----------|
| `tests-skipped` | outcome != success AND tests_passed IS NULL | process |
| `tests-failed` | tests_passed = 0 | code |
| `lint-failed` | lint_passed = 0 | code |
| `scope-creep` | files_touched > 8 OR duration > 1800s | scope |
| `quick-failure` | outcome = failure AND duration < 60s | process |
| `long-running` | duration > 3600s | scope |
| `no-test-files` | files_touched has no *_test* files | process |
| `error-retry` | same task appears multiple times | process |

Custom patterns can be defined via `loop patterns add`.

## Query Matching

When an agent queries with a task description, relevance is determined by:

1. **Tag overlap** — runs sharing tags with the query terms
2. **Task similarity** — keyword matching between task descriptions (TF-IDF style)
3. **File overlap** — if the query mentions specific files, find runs that touched them
4. **Recency** — more recent runs weighted higher
5. **Outcome weighting** — failures with known patterns are more informative than successes

The query returns insights first (pre-computed, high value), then relevant run summaries, then pattern warnings.

## File Layout

```
learning-loop/
├── cmd/
│   └── loop/
│       └── main.go              # CLI entrypoint
├── internal/
│   ├── db/
│   │   ├── db.go                # SQLite connection, migrations
│   │   ├── db_test.go
│   │   ├── runs.go              # Run CRUD
│   │   ├── runs_test.go
│   │   ├── patterns.go          # Pattern CRUD
│   │   ├── patterns_test.go
│   │   ├── insights.go          # Insight CRUD
│   │   └── insights_test.go
│   ├── ingest/
│   │   ├── ingest.go            # Run ingestion + pattern detection
│   │   └── ingest_test.go
│   ├── analyze/
│   │   ├── analyze.go           # Analysis engine (hourly/daily/weekly)
│   │   ├── analyze_test.go
│   │   ├── patterns.go          # Pattern detection rules
│   │   └── patterns_test.go
│   ├── query/
│   │   ├── query.go             # Query engine
│   │   ├── query_test.go
│   │   ├── match.go             # Relevance matching
│   │   └── match_test.go
│   └── report/
│       ├── report.go            # Report generation
│       └── report_test.go
├── go.mod
├── go.sum
├── PRD.md
├── CRITIQUE.md
├── VISION.md
└── RESULTS.md
```

## What "Done" Looks Like

1. `loop ingest` accepts a JSON run record and stores it with pattern detection
2. `loop query "fix auth bug"` returns relevant learnings as injectable text
3. `loop analyze` generates insights from accumulated run data
4. `loop patterns` shows the pattern registry
5. `loop insights` shows actionable recommendations
6. `loop runs` shows run history with outcomes
7. `loop status` shows system health
8. All commands have tests
9. Single binary, zero external dependencies (embedded SQLite)
10. Works as both one-shot CLI and cron-triggered tool

## What's Explicitly NOT in v1

- Cross-machine sync (single host, single database)
- Web UI or HTML dashboard
- Real-time streaming / websockets
- A/B testing of prompts (can be added later)
- Automatic prompt mutation (insights are for humans/agents to act on)
- Integration with specific agent frameworks (agent-agnostic input)
- Semantic/embedding-based similarity (keyword matching is enough to start)
