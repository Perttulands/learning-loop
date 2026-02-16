# Agent Learning Loop

A closed-loop system where every agent run — success or failure — automatically improves future runs.

## The Flywheel

```
Dispatch → Execute → Verify → Record → Analyze → Score → Select → Refine → Dispatch
    ↑                                                                          |
    └──────────────────────────────────────────────────────────────────────────┘
```

## Problem

The agentic coding swarm on ahjo-1 executes 100+ runs but learns nothing between them. Verification pass rate sits at ~19%. Templates are underused (95/102 runs use `custom`). Failures repeat. This project closes the feedback loop.

## Architecture

Four nested feedback loops at different cadences:

| Loop | Cadence | Script | Purpose |
|------|---------|--------|---------|
| **Run Feedback** | Per-run | `feedback-collector.sh` | Classify outcomes, tag failure patterns |
| **Template Scoring** | Hourly | `score-templates.sh` | Aggregate per-template/agent performance scores |
| **Prompt Refinement** | Daily | `refine-prompts.sh` | Auto-generate improved template variants via A/B testing |
| **Strategy Evolution** | Weekly | `weekly-strategy.sh` | Cross-template learnings and system-level recommendations |

## Tech Stack

- **Bash scripts** — all components are standalone bash scripts
- **JSON state files** — reads from `~/.openclaw/workspace/state/`
- **jq** — JSON processing
- **Cron** — scheduled execution

## Project Structure

```
learning-loop/
├── scripts/          # All executable scripts
├── state/            # Runtime state (feedback, scores, reports)
├── config/           # Configuration and schemas
├── PRD_LEARNING_LOOP.md  # Ralph-format PRD with sprints
├── README.md
└── go.mod
```

## Scripts

| Script | Cadence | Purpose |
|--------|---------|---------|
| `scripts/feedback-collector.sh` | Per-run | Classify outcomes, extract signals, detect failure patterns |
| `scripts/detect-patterns.sh` | Per-run | Tag failure patterns, update `state/feedback/pattern-registry.json` |
| `scripts/score-templates.sh` | Hourly (cron) | Aggregate feedback into `state/scores/template-scores.json` and `state/scores/agent-scores.json` |
| `scripts/select-template.sh` | Per-dispatch | Recommend template + agent based on scores and A/B tests |
| `scripts/refine-prompts.sh` | Daily (cron) | Generate template variants from failure data |
| `scripts/ab-tests.sh` | On-demand | A/B test lifecycle: create, pick, record, evaluate |
| `scripts/guardrails.sh` | Integrated | Safety: variant limits, rollback, loop breaker |
| `scripts/notify.sh` | Integrated | Alerts via wake-gateway (variant events, regressions, weekly report) |
| `scripts/manage-patterns.sh` | On-demand | Pattern registry: list, detail, mitigate, effectiveness |
| `scripts/weekly-strategy.sh` | Weekly (cron) | Cross-cutting strategy report with recommendations |
| `scripts/backfill.sh` | One-time | Process historical runs through feedback pipeline |
| `scripts/install-cron.sh` | One-time | Install/remove cron entries from `config/crontab.txt` |

See [docs/flywheel.md](docs/flywheel.md) for architecture details and [docs/templates-guide.md](docs/templates-guide.md) for the variant lifecycle.

## Goal

Within 50 runs of activation, achieve ≥80% verification-pass rate (up from ~19%).

## Status

See [PRD_LEARNING_LOOP.md](PRD_LEARNING_LOOP.md) for sprint breakdown and task tracking.
