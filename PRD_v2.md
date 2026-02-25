# PRD v2 — Learning Loop

*Mode: Prescriptive. Revised after studying all 6 sibling projects and the soul of Polis.*

---

## The Whole Board

Six projects are being built simultaneously:

| Project | Role |
|---------|------|
| **Panopticon** | Flight recorder. Captures structured traces of everything agents do. |
| **Forge** | Lifecycle manager. Spawns workers, tracks progress, collects results. |
| **Centurion** | Quality gate. Tests, lint, truthsayer, risk scoring, merge verdicts. |
| **Learning Loop** | ??? — this document answers this question. |
| **Sentinel** | Operations dashboard. Web UI, real-time agent visibility. |
| **Agora UI** | Living city map. Strategy game visualization of Polis. |

The intended data flow:

```
Forge spawns worker
  → Worker works (Panopticon captures trace)
    → Worker finishes (Centurion gates quality)
      → Results graded (Learning Loop extracts wisdom)
        → Next worker spawns (Learning Loop injects context)
          → Loop closes
```

Sentinel and Agora UI are read-only views on top of this pipeline.

---

## The Overlap Problem

I built Learning Loop as a standalone system that ingests JSON run records, stores them in SQLite, detects patterns, generates insights, and answers queries. But look at what the other projects already do:

**Panopticon** captures: agent, task, events (tool calls, file writes, commands, decisions, errors), outputs, outcome, cost. It has `panopticon patterns` for extracting recurring sequences. It has `panopticon query` for searching traces. It has `panopticon feed` — explicitly designed as Learning Loop's input.

**Forge** captures: task spec, worker assignment, bead creation, quality gate results, graded outcomes. It explicitly says: "Results graded and fed to learning-loop" and "Failed tasks get retry with learning-loop context."

My v1 `loop ingest` accepts a JSON run record with fields like duration, files_touched, tools_used, tests_passed, outcome. **This is a strict subset of what Panopticon already captures.** The run record I defined IS the trace, just flattened. I built a data capture layer for a system that already has one.

And my `loop analyze` generates statistical insights like "tests were skipped 40% of the time." **Panopticon's `patterns` command already extracts recurring sequences.** I built a pattern detection layer for a system that already has one.

So what does Learning Loop actually provide that nothing else does?

---

## What Nothing Else Provides

Three things. Only three. But they're the three that matter most.

### 1. Explicit Citizen Learnings

Panopticon captures what happened. Forge captures outcomes. Centurion captures quality. **Nobody captures what the citizen understood.**

"When working on auth middleware, reading the existing tests first produced a clean solution in 20 minutes." That's not a trace event. It's not a quality verdict. It's not a pattern statistic. It's a *learning* — something a citizen internalized and wants the city to remember.

This is what Golden Truth I demands: *we always prioritize learning over results. A documented failure is a contribution. An undocumented success is a liability.* The learning loop is the system that makes this truth operational. Not by tracking success rates. By capturing understanding.

### 2. Cross-Bead Wisdom Synthesis

Panopticon can tell you what happened in trace abc123. Forge can tell you the outcome of bead learning-loop-3f9. But nobody answers: **"Across all beads that involved database migrations, what did we learn?"**

That requires:
- Matching beads by similarity (tags, files, task descriptions)
- Aggregating patterns across matched beads
- Synthesizing explicit learnings from multiple citizens
- Ranking by relevance, recency, and learning quality
- Producing a coherent, attributed summary

This is the query engine. It reads from Panopticon's traces AND from its own learnings store, and it produces something neither can produce alone: institutional wisdom.

### 3. Pre-Work Context Injection

Forge spawns a worker. Before that worker starts, it needs context: what has the city learned about this kind of work? What patterns should it watch for? What did previous citizens discover?

Nobody else provides this. Panopticon is a recorder, not an advisor. Forge is a lifecycle manager, not a teacher. Centurion evaluates after the fact, not before.

The learning loop is the thing that closes the loop — that turns past experience into future advantage. The `loop context` command is the single most important feature in the entire system.

---

## What This Project Should Be

**The wisdom layer of Polis.**

Not a data capture system (that's Panopticon). Not a lifecycle manager (that's Forge). Not a quality gate (that's Centurion). The thing that turns accumulated experience into actionable knowledge.

Three capabilities, nothing more:

1. **Capture learnings** — explicit citizen reflections, linked to beads
2. **Synthesize wisdom** — cross-bead pattern aggregation and learning retrieval
3. **Inject context** — pre-work advice that makes the next bead smarter

### The Sentence

**Loop is where the city remembers what it learned.**

---

## Data Sources

Learning Loop does NOT do its own data capture for telemetry. That's Panopticon's job. Instead:

### From Panopticon (primary data source)

```
panopticon feed --since <last-sync> --format jsonl
```

Learning Loop periodically reads Panopticon's feed to get trace summaries: bead ID, citizen, outcome, duration, files touched, tools used, test/lint results, error messages, cost. Pattern detection runs on these summaries.

**If Panopticon isn't available** (it's being built in parallel), Learning Loop falls back to its own `loop ingest` command — same JSON format as Panopticon's feed output. When Panopticon ships, `loop ingest` becomes a thin wrapper around `panopticon feed`. The interface is the same; only the source changes.

### From Beads (task context)

```
bd show <bead-id> --format json
```

Learning Loop reads bead metadata for task descriptions, tags, dependencies, and status. This is how it knows what a bead was about without requiring the run record to duplicate that information.

### From Citizens (explicit learnings)

```
loop learn <bead-id> "what I learned"
```

This is Learning Loop's own data. The thing no other system captures. Stored in its own SQLite database alongside pattern data.

---

## Data Model

### What Learning Loop Stores (its own SQLite)

```sql
-- Summaries derived from Panopticon traces (or direct ingest as bridge)
runs (
    bead_id       TEXT PRIMARY KEY,
    citizen       TEXT NOT NULL,
    outcome       TEXT NOT NULL,
    duration_s    INTEGER,
    files_touched TEXT,  -- JSON array
    tools_used    TEXT,  -- JSON array
    tests_passed  INTEGER,
    lint_passed   INTEGER,
    error_message TEXT,
    tags          TEXT,  -- JSON array
    timestamp     TEXT NOT NULL,
    source        TEXT DEFAULT 'ingest'  -- 'ingest' or 'panopticon'
)

-- Explicit citizen learnings — the most important table
learnings (
    id          TEXT PRIMARY KEY,
    bead_id     TEXT NOT NULL,
    citizen     TEXT NOT NULL,
    text        TEXT NOT NULL,
    tags        TEXT,  -- JSON array, auto-derived from bead + manual
    created_at  TEXT NOT NULL
)

-- Auto-detected patterns (carried from v1, still useful)
patterns (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    category    TEXT NOT NULL,
    impact      TEXT NOT NULL,
    frequency   INTEGER DEFAULT 0
)

-- Which patterns matched which beads
pattern_matches (
    bead_id    TEXT NOT NULL,
    pattern_id TEXT NOT NULL,
    UNIQUE(bead_id, pattern_id)
)
```

### What Learning Loop Does NOT Store

- Raw trace events (Panopticon owns these)
- Bead metadata (beads owns this)
- Quality verdicts (Centurion owns these)
- Agent session state (Forge owns this)

Learning Loop stores derived knowledge: patterns, learnings, and enough run summary to do matching. It's small, permanent, and high-signal.

---

## CLI Surface

```
loop learn  <bead-id> "text"                    Record what a citizen learned
loop context <bead-id>                           Pre-work injection for a bead
loop query  <description>                        Get learnings by topic
loop sync                                        Pull new traces from Panopticon
loop ingest [--bead ID] [--citizen NAME] [file]  Bridge: manual run ingest
loop status                                      What has the city learned?
loop patterns [--citizen NAME]                   Detected patterns
loop learnings [--citizen NAME] [--bead ID]      Citizen-recorded learnings
loop init                                        Initialize database
loop version                                     Print version
```

**8 commands, not 12.** Removed: `analyze` (automatic on sync/ingest), `insights` (replaced by `learnings`), `runs` (Panopticon owns run history), `report` (Sentinel/Agora owns reporting).

### The Most Important Commands

**`loop learn`** — Golden Truth I made operational. A citizen finishes a bead and records what they understood. 30 seconds. Becomes permanent institutional knowledge.

**`loop context`** — The closer of the loop. Takes a bead ID, finds similar past beads, retrieves learnings and patterns, outputs injectable markdown. This is what Forge calls before spawning a worker.

**`loop query`** — The human-facing version of `context`. Free-text query instead of bead ID. For when a citizen wants to ask "what does the city know about X?" without having a specific bead.

---

## Pattern Detection

Keep the 8 patterns from v1. Add 3 that are uniquely Polis:

| # | Pattern | What It Embodies |
|---|---------|-----------------|
| 9 | `no-learning` | Bead closed without a recorded learning. Golden Truth I: we punish the failure to capture learning. |
| 10 | `repeated-pattern` | Same pattern hit 3+ times by the same citizen. Signal that structure needs to change (Golden Truth II). |
| 11 | `citizen-growth` | A pattern that used to appear for a citizen but stopped. The system learned. Celebrate it. |

These three don't exist in any generic agent tool. They exist because Polis has citizens with identity, and because Polis cares about learning over results.

---

## Integration Points

### With Forge (the primary consumer)

```
# Forge calls this before spawning a worker:
loop context <bead-id> --inject

# Forge calls this after collecting results:
loop sync  # or loop ingest if Panopticon isn't ready
```

Forge doesn't need to know how learning works. It just calls `context` for pre-work and `sync`/`ingest` for post-work.

### With Panopticon (the primary data source)

```
# Learning Loop pulls trace summaries:
panopticon feed --since "2026-02-22" --format jsonl | loop sync --stdin

# Or via file:
loop sync --from ~/.panopticon/
```

Learning Loop reads Panopticon's feed. It does NOT hook into Panopticon's capture path. The relationship is pull, not push — Learning Loop syncs when it needs data, not on every trace event.

### With Beads (task context)

```
# Learning Loop reads bead metadata for matching:
bd show <bead-id> --format json
```

When `loop context` runs, it reads the target bead's tags and description to find similar past beads. It doesn't modify beads.

### With Centurion (quality signal)

Centurion's verdicts are captured in Panopticon traces as `gate.verdict` events. Learning Loop reads these through Panopticon — no direct integration needed.

---

## Context Injection Format

The output of `loop context` and `loop query --inject`:

```markdown
## What Polis has learned about this kind of work

**From 4 similar beads (3 success, 1 failure):**

1. When working on database migrations, always write the rollback path first.
   The CREATE IF NOT EXISTS pattern on every open is simple and works.
   — Mercury, bead learning-loop-3f9

2. Pure-Go SQLite avoids CGO but pulls in many transitive deps. Run go mod tidy
   early to catch issues before they compound.
   — Mercury, bead learning-loop-3f9

3. Schema changes that touch the runs table require updating both scanRun
   and scanRunRows — easy to miss the second one.
   — Mercury, bead learning-loop-0o6

**Patterns to watch for:**
- scope-creep: 2 of 4 similar beads touched >8 files (both took >1hr)
- no-test-files: 1 bead modified source without test updates (failed)
```

Every learning has attribution. Citizens evaluate the source, not just the claim.

---

## Opinions on the Other Projects

The user asked me to think about the whole board. Here's what I actually think:

### Sentinel should not be a separate project.

Sentinel is a web dashboard showing agent status, relay messages, beads, and health metrics. Agora UI is a web frontend showing agent status, relay messages, beads, and health metrics — as a living city map.

They display the same data. Building two web frontends for one system is wasteful. Sentinel's data aggregation backend (reading from relay, beads, argus, tmux) is exactly what Agora UI needs as its server. Build one thing: Agora UI, with Sentinel's backend as its data layer. The operational detail views that Sentinel would provide become click-to-expand panels in Agora.

If Agora UI is too ambitious for v1, build the data backend first (what Sentinel would have been) and put a minimal HTML frontend on it. Then replace the frontend with the game map. But don't build two permanent frontends.

### The other four projects are correctly scoped.

- **Panopticon** is the data layer. Everything reads from it. Correctly positioned.
- **Forge** is the orchestrator. It calls Centurion and Learning Loop. Correctly positioned.
- **Centurion** is the quality gate. Standalone, composable. Correctly positioned.
- **Agora UI** is the visual layer. Should absorb Sentinel's backend work.

### Learning Loop is correctly scoped — now.

The first version of this PRD (my v1 build) was too broad. It tried to be the data capture layer, the analysis engine, the query system, and the reporting tool. With Panopticon handling data capture and Sentinel/Agora handling display, Learning Loop narrows to what only it can do: learnings, wisdom synthesis, and context injection.

---

## What's Intentionally Out of Scope

1. **Raw data capture.** Panopticon owns this. Learning Loop reads from it.
2. **Run history display.** Panopticon and Sentinel/Agora own visualization.
3. **Quality gating.** Centurion owns this.
4. **Agent lifecycle.** Forge owns this.
5. **Semantic/embedding search.** Keyword matching is sufficient at current scale.
6. **Automated prompt mutation.** A/B testing with small samples is statistically invalid.
7. **Cron cadences.** Event-driven (sync on demand) is sufficient.

---

## Language

Go. Same as Panopticon, Forge, Centurion, and Sentinel. The existing v1 code works, the ecosystem is right for CLI + embedded SQLite, and matching the other projects means shared patterns and tooling. No reason to change.

---

## The Name

"Learning Loop" describes the cycle: work → capture → learn → inject → better work. The project is one component of that cycle, not the whole cycle. But the name is fine — it's clear, it's established, and the beads already reference it.

If it were being named today, something more Polis-native would fit. In ancient Greece, you consulted the Oracle before a great undertaking. `loop context "fix auth middleware"` is literally "Oracle, what should I know?" But renaming a project with 7 closed beads and 4,000+ lines of code for aesthetics is not worth the churn.

---

## Migration Path

v1 → v2 is evolution, not rewrite:

1. Add `learnings` table to SQLite schema.
2. Add `source` column to runs table (`'ingest'` or `'panopticon'`).
3. Rename `agent` → `citizen` in the runs table.
4. Add `bead_id` column to runs table.
5. Implement `loop learn` command (new, most important).
6. Implement `loop context` command (new, second most important).
7. Implement `loop sync` command (Panopticon bridge).
8. Merge `analyze` into `ingest`/`sync` (auto-trigger on new data).
9. Add the three Polis-native patterns (no-learning, repeated-pattern, citizen-growth).
10. Update output formats to include citizen attribution.
11. Remove `analyze`, `report` as standalone commands.
12. Keep `ingest` as bridge until Panopticon ships.

The existing ingest, query, pattern detection, and SQLite infrastructure carries forward. The test suite needs updating for the new schema and commands, but the architecture is sound.

---

## What Success Looks Like

**After 10 beads:** The system has enough data to produce relevant context. A citizen starting a new bead sees learnings from past beads in similar domains.

**After 30 beads:** The `no-learning` pattern starts flagging beads that close without reflection. Citizens internalize the habit of recording learnings — not because they're told to, but because the structure makes it natural.

**After 100 beads:** A new citizen joins Polis. They pick up their first bead. Before writing a line of code, they receive the distilled wisdom of every citizen who came before. They start from 100 beads of institutional knowledge, not from zero.

**The experiment:** Golden Truth IV says Polis is exploring whether agents with identity and soul outperform stateless tools. Learning Loop is how we measure this. If citizen-attributed, context-aware learnings produce better outcomes than statistical patterns alone, the hypothesis is confirmed. The data will show it.

---

## Summary

v1 was a competent generic tool. v2 is a specific component of a specific city.

The boundaries are clear:
- **Panopticon** captures what happened.
- **Learning Loop** captures what it means.
- **Forge** acts on what was learned.

The learning loop is small, focused, and irreplaceable. It does three things no other system does: capture citizen learnings, synthesize cross-bead wisdom, and inject context before work begins. That's it. That's enough.
