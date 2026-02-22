# Learning Loop — Closed-Loop Agent Improvement System

## Problem

Agents run, succeed or fail, and learn nothing. The next run starts from zero. Failures repeat. Good patterns aren't captured. The swarm has amnesia.

The existing learning-loop repo at `/home/polis/tools/learning-loop/` has the architecture (4-cadence feedback: per-run, hourly, daily, weekly) but it was built for chrote's layout and hasn't been wired into Polis.

## Vision

Every agent run feeds a flywheel. Successes get their patterns extracted. Failures get analyzed for root causes. Over time, the system builds a library of "what works" that gets injected into future runs as context. The 19% → 80% pass rate improvement that was promised.

## What "Wow" Looks Like

- Per-run: Agent finishes → learning-loop captures outcome, duration, tools used, error patterns
- Hourly: Batch analysis of recent runs → pattern extraction, failure clustering
- Daily: Strategy review → which templates/approaches win, which lose, recommendations
- Weekly: Meta-analysis → system-level insights, rule proposals for truthsayer/oathkeeper
- Patterns stored as searchable, taggable entries (not just log files)
- Agents can query the loop: "what worked last time someone tried X?"
- Integrates with beads for tracking improvement over time
- Cron-driven cadences that actually run (OpenClaw cron or systemd timers)
- Dashboard output: trend lines, pass rates, top failure modes

## Reference Material

- Learning Loop source: `/home/polis/tools/learning-loop/` (Go project, study it deeply)
- Chrote's cron setup: had hourly/daily/weekly learning-loop jobs
- Beads: `bd` for tracking
- Relay: `relay send` for cross-agent communication of learnings

## Technical Constraints

- Language: Go (match existing source) or Node.js
- Must produce machine-readable output (JSON/JSONL)
- Must integrate with beads for tracking
- Storage: local filesystem (JSONL or SQLite), not a remote database
- Must be runnable as both CLI (one-shot) and cron (scheduled)
- Cron config should be expressible as OpenClaw cron jobs

## Non-Goals (v1)

- Cross-machine learning (single host only)
- Real-time streaming (batch is fine)
- UI (CLI + file output is enough)

## Success Criteria

- Can ingest a real agent run output and extract actionable patterns
- Patterns are queryable by future agent runs
- 4 cadences run on schedule without human intervention
- After 20+ runs, measurable improvement in agent success rates
- Beads trail shows the evolution of learnings over time
