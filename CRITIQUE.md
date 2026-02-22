# PRD Critique — Learning Loop

## 1. The PRD Lies About the Existing System

> "Learning Loop source: `/home/polis/tools/learning-loop/` (Go project, study it deeply)"

**It's not a Go project.** It's 3,450 lines of Bash across 18 scripts with 30+ test suites and 500+ assertions. The `go.mod` is a stub. This matters because the PRD frames this as "porting a Go codebase" when the actual task is "rewriting a mature Bash system in a compiled language." Different framing, different decisions.

## 2. The Existing System Is More Complete Than the PRD Implies

The PRD describes the 4-cadence model as aspirational ("What Wow Looks Like"). In reality, the existing system **already implements all of this**:

- Per-run feedback collection with 8 failure pattern detectors
- Hourly template/agent scoring with regression detection
- Daily prompt refinement with A/B testing, variant promotion, human-gated approvals
- Weekly strategy reports with cross-cutting analysis
- Guardrails: variant caps, rollback logic, refinement loop breakers
- Notifications via wake-gateway
- Comprehensive cron integration
- Dashboard generation

The PRD doesn't acknowledge this. It reads like none of this exists. This is dangerous — it could lead to building something strictly worse than what's already there.

## 3. What's Actually Vague

### "Agents can query the loop: what worked last time someone tried X?"

This is the single most valuable feature in the entire PRD, and it gets **one bullet point** with zero specification. Questions unanswered:

- What's the query interface? CLI command? API? File read?
- What does the query return? Raw data? Formatted advice? Injected context?
- How does an agent know what to query for? Who constructs the query?
- What's the relevance matching? Keyword? Semantic? Template-based?
- What happens when there's no relevant history? (Cold start)

### "Integrates with beads for tracking improvement over time"

How? Beads is an issue tracker. Learning loop is a feedback system. The integration surface is undefined. Does every pattern become a bead? Does every weekly insight become a bead? Or is it just "reference beads in commit messages"?

### "Cron-driven cadences that actually run"

The old system HAD cron. If it didn't "actually run," why not? Was it a deployment problem? A configuration problem? A monitoring problem? The PRD doesn't diagnose why the old cron setup failed, which means the new one will likely fail the same way.

### "Dashboard output: trend lines, pass rates, top failure modes"

Who looks at this dashboard? If it's for humans, a CLI table is fine. If it's for agents, structured JSON is better. The audience determines the format and the old system already generates both HTML and JSON.

## 4. Wrong Assumptions

### Assumption: We need a full rewrite

The existing Bash system works. It's tested. It's battle-hardened. The right approach might be: port the core data model and query interface to Go/Node, then gradually replace individual scripts, rather than starting from zero.

### Assumption: The 4-cadence model is the right architecture

The cadence model assumes a high-volume agent farm (Athena's swarm). If Polis runs fewer agents, hourly scoring is overkill — you'd score the same 2 runs repeatedly. The system should be event-driven (trigger on new data) not calendar-driven (run on schedule).

### Assumption: Templates are the unit of improvement

The existing system optimizes at the template level (bug-fix, feature, refactor, etc.). But the most impactful learnings are often cross-cutting: "always run tests before committing" applies to ALL templates. The template-centric model misses systemic patterns.

### Assumption: A/B testing prompts is the improvement mechanism

A/B testing with N=10 samples and a 0.1 score threshold is not statistically valid. The existing system acknowledges this but plows ahead anyway. For a small-scale deployment, curated human-reviewed insights will outperform automated prompt mutation every time.

## 5. What's Missing

### Input specification

What does a "run record" look like in Polis? The existing system expects chrote/athena's specific JSON format with fields like `status`, `exit_code`, `verification`, `attempt`, `template`, `agent`, `duration_seconds`. Is Polis's agent output compatible? If not, the entire feedback collector needs a new parser.

### Output specification

What format should learnings be in to be useful to future agents? A pattern like "test-failure-after-completion" is useful to a scoring algorithm but useless to an agent that doesn't know what that means. The system needs to produce **natural language advice** ("Run your tests before declaring done — 34% of similar tasks failed because they skipped testing").

### Cold start strategy

With 0 historical data, the system produces nothing useful. The PRD needs a bootstrap plan: seed data, initial rules, or a "manual mode" where humans input learnings until the system has enough data to be autonomous.

### Integration with the actual agent runtime

How does an agent get learning context injected? Is it a pre-run hook that appends to the system prompt? A file that gets included? An environment variable? This is the critical path and it's completely unspecified.

### Error taxonomy

The existing system has 8 patterns. But these are specific to chrote's workflow. What are Polis's failure modes? The pattern detector needs to be configurable, not hardcoded.

### Storage migration path

The PRD says "JSONL or SQLite." These are very different choices with very different query capabilities. SQLite gives you indexed queries, aggregation, and joins. JSONL gives you append-only simplicity. For a query-heavy system ("what worked last time?"), SQLite is the obvious choice. The PRD should commit.

## 6. What Would Make This 10x Better

### 1. The query interface IS the product

Forget dashboards. Forget cron schedules. The killer feature is: an agent is about to start work, it asks "what should I know?", and it gets back a curated set of relevant learnings that measurably improve its success rate. Everything else is plumbing.

### 2. Structured knowledge, not just scores

The existing system reduces everything to a single score (0-1). But agents need structured knowledge: "When fixing auth bugs, always check the middleware chain first" is worth more than "bug-fix template score: 0.74." The system should produce and store **actionable insights**, not just metrics.

### 3. Event-driven, not calendar-driven

Trigger analysis when new data arrives, not on a fixed schedule. This eliminates the "cron didn't actually run" problem and means insights are available immediately after a run completes, not an hour later.

### 4. Agent-agnostic input

Don't couple to a specific agent framework. Accept a simple, well-documented input format (JSON) that any agent can produce. The existing system is tightly coupled to chrote's workspace layout — this is why it can't be "wired into Polis."

### 5. Single binary, zero dependencies

18 Bash scripts + jq + bc + cron is a deployment nightmare. A single Go binary with SQLite embedded (via modernc.org/sqlite, no CGO) that handles ingest, analysis, query, and scheduled tasks internally would be transformatively simpler.

### 6. Composable CLI

Instead of one monolithic tool, design around Unix composability:
```
loop ingest <run.json>        # Record a run
loop query "auth bug fix"     # Get relevant learnings
loop analyze                  # Run analysis on new data
loop patterns                 # List known patterns
loop insights                 # Show actionable insights
loop status                   # System health
```

### 7. Learnings as injectable context

The output of `loop query` should be a block of text that can be directly concatenated into an agent's system prompt or CLAUDE.md. No parsing required. No API integration. Just text that makes the agent smarter.

## Summary

The PRD describes a system that already exists (in Bash), underspecifies the only feature that matters (queryable learnings), and overspecifies plumbing (cron schedules, dashboards). The rebuild should focus ruthlessly on: **ingest → analyze → query → inject**. Everything else is decoration.
