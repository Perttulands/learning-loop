# Learning Loop

![Learning Loop](images/learning-loop.jpg)

*The Ouroboros. Half bronze, half circuit board. Every ending feeds the next beginning.*

---

**Your AI agents keep making the same mistakes. This fixes that.**

A single binary that watches what your agents do, learns what works, and injects that knowledge into future runs. No config files. No infrastructure. Just `loop ingest` and `loop query`.

```
$ loop query "fix authentication middleware"

 LEARNINGS  From 23 similar runs (78% success rate)

  1. Always run the full test suite before committing — 34% of auth
     bug fixes failed because tests were skipped.

  2. Auth middleware changes typically touch 2-4 files. If you're
     editing more than 5, you're probably scope-creeping.

  3. The most successful approach: read the existing tests first,
     then make the fix, then run tests, then commit.

 WATCH OUT  Patterns that caused failures in similar tasks

  ● tests-skipped          12 occurrences   HIGH impact
  ● scope-creep             4 occurrences   MEDIUM impact

 SUCCESS SIGNALS  What winning runs looked like

  ✓ Edited test files alongside source     → 92% success rate
  ✓ Completed in under 10 minutes          → 85% success rate
  ✓ Used grep before editing               → 88% success rate
```

## The Flywheel

```
Dispatch → Execute → Verify → Record → Analyze → Score → Select → Refine → Dispatch
    ↑                                                                          |
    └──────────────────────────────────────────────────────────────────────────┘
```

Every agent run produces signal. What worked. What failed. How long it took. What tools it used. What files it touched. Today, all of that signal evaporates the moment the run ends.

Learning Loop captures it, finds patterns, and feeds it back. Your agents get smarter with every run without you changing a single prompt.

## Install

```bash
go install github.com/polis/learning-loop/cmd/loop@latest
```

## Quick Start

```bash
# Initialize (creates .learning-loop/loop.db)
loop init

# After an agent run, ingest the result
loop ingest run.json

# Or pipe from stdin
echo '{"id":"run-1","task":"Fix login bug","outcome":"success","tests_passed":true}' | loop ingest -

# Before the next run, ask what the agent should know
loop query "fix authentication bug"

# See what the system has learned
loop status
loop patterns
loop insights
```

## Architecture

```
                     ┌──────────────────────────────────────────┐
                     │             loop CLI                     │
                     │                                          │
 Agent finishes ───► │  ingest   Parse → Detect → Store         │
                     │                                          │
 Agent starting ───► │  query    Match → Rank → Format          │
                     │                                          │
 Cron / manual ────► │  analyze  Aggregate → Cluster → Insight  │
                     │                                          │
 Human ────────────► │  status · patterns · insights · runs     │
                     └──────────────────┬───────────────────────┘
                                        │
                                        ▼
                             ┌────────────────────┐
                             │  SQLite (embedded)  │
                             │  Zero dependencies  │
                             │  Single file DB     │
                             └────────────────────┘
```

## CLI Surface

```
loop ingest <file|->         Ingest a run record (file or stdin)
loop query <description>     Get relevant learnings for a task
loop query --inject          Output as injectable context block
loop query --json            Machine-readable output
loop analyze                 Run analysis on new data
loop status                  Dashboard: runs, patterns, health
loop patterns                List detected patterns with stats
loop insights                Show actionable insights
loop runs                    List recent runs with outcomes
loop runs --last 20          Limit to last N
loop runs --outcome failure  Filter by outcome
loop report                  Generate full summary report
loop init                    Initialize database
loop version                 Print version
```

Every command outputs beautiful, color-coded terminal output by default. Add `--json` for machine consumption.

## Run Record Format

```json
{
  "id": "run-a8f3e",
  "task": "Fix authentication bug in login middleware",
  "outcome": "success",
  "duration_seconds": 342,
  "timestamp": "2026-02-22T14:30:00Z",
  "tools_used": ["read", "edit", "bash"],
  "files_touched": ["src/auth/middleware.go", "src/auth/middleware_test.go"],
  "tests_passed": true,
  "lint_passed": true,
  "tags": ["auth", "bug-fix"],
  "agent": "claude-code",
  "model": "claude-opus-4-6"
}
```

Only `id`, `task`, and `outcome` are required. Everything else enriches the analysis.

## Pattern Detection

8 patterns detected automatically on every ingest:

| Pattern | What It Catches | Impact |
|---------|----------------|--------|
| `tests-skipped` | Task ended without running tests | HIGH |
| `tests-failed` | Tests ran but failed | HIGH |
| `lint-failed` | Linter found issues | MEDIUM |
| `scope-creep` | Too many files (>8) or too long (>30min) | MEDIUM |
| `quick-failure` | Failed in under 60 seconds | HIGH |
| `long-running` | Took over an hour | MEDIUM |
| `no-test-files` | Modified source but not tests | MEDIUM |
| `success-with-errors` | Marked success but had errors | MEDIUM |

## Query Matching

Relevance scoring uses:
1. **Tag overlap** between query terms and run tags
2. **Keyword similarity** between task descriptions
3. **File references** mentioned in the query
4. **Recency decay** — recent runs weighted higher
5. **Outcome signal** — failures with patterns are most informative

## File Layout

```
learning-loop/
├── cmd/loop/main.go          CLI entrypoint
├── internal/
│   ├── db/                   SQLite layer (connection, CRUD, migrations)
│   ├── ingest/               Run parsing, validation, pattern detection
│   ├── analyze/              Aggregation, clustering, insight generation
│   ├── query/                Relevance matching, result formatting
│   └── report/               Report generation
├── e2e_test.go               End-to-end test suite
├── city.toml                 City-readiness contract
├── go.mod
└── README.md
```

## What Makes This Different

1. **Zero config** — `loop init` and you're running
2. **Single binary** — no Redis, no Postgres, no Docker
3. **Agent-agnostic** — works with any AI agent that can produce JSON
4. **Injectable output** — `loop query` output goes straight into prompts
5. **Beautiful CLI** — colors, formatting, progress — not log spam
6. **Immediate value** — useful after 3 runs, powerful after 30

## Part of Polis

Learning Loop was forged in the Agora — an autonomous multi-agent platform where AI agents build software and a bronze serpent makes sure they learn from every failure.

The ouroboros — the serpent eating its own tail — is the oldest symbol of cycles that produce something. Not repetition. Transformation. Where the bronze scales meet the teeth, they become circuit board. Fiber-optic flowers bloom from the bite point. Four rings mark its body: per-run, hourly, daily, weekly. And beneath the serpent, a garden grows, fed by everything it consumes.

## License

MIT
