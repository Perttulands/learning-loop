# Agent Learning Loop

A closed-loop system where every agent run — success or failure — automatically improves future runs.

## The Flywheel

```
Dispatch → Execute → Verify → Record → Analyze → Score → Select → Refine → Dispatch
    ↑                                                                          |
    └──────────────────────────────────────────────────────────────────────────┘
```

## Problem

The agentic coding swarm executes 100+ runs but learns nothing between them. Verification pass rate sits at ~19%. Templates are underused (95/102 runs use `custom`). Failures repeat. This project closes the feedback loop.

## Architecture

Four nested feedback loops at different cadences:

| Loop | Cadence | Script | Purpose |
|------|---------|--------|---------|
| **Run Feedback** | Per-run | `feedback-collector.sh` | Classify outcomes, tag failure patterns |
| **Template Scoring** | Hourly | `score-templates.sh` | Aggregate per-template/agent performance scores |
| **Prompt Refinement** | Daily | `refine-prompts.sh` | Auto-generate improved template variants via A/B testing |
| **Strategy Evolution** | Weekly | `weekly-strategy.sh` | Cross-template learnings and system-level recommendations |

## Quality Signals

Feedback records include optional qualitative fields for Opus-based judging:

- `opus_quality_score` (0-1)
- `opus_judge` payload (`judge_model`, `style_rating`, `maintainability_rating`, `critique`, `judged_at`)

These fields default to `null` until judge integration is enabled.

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
| `scripts/ab-tests.sh` | On-demand | A/B test lifecycle: create, pick, record, evaluate, review queue, approve |
| `scripts/guardrails.sh` | Integrated | Safety: variant limits, rollback, loop breaker |
| `scripts/notify.sh` | Integrated | Alerts via wake-gateway (variant events, regressions, weekly report) |
| `scripts/manage-patterns.sh` | On-demand | Pattern registry: list, detail, mitigate, effectiveness |
| `scripts/weekly-strategy.sh` | Weekly (cron) | Cross-cutting strategy report with recommendations |
| `scripts/retrospective.sh` | On-demand | Compare pre-loop vs post-loop metrics, threshold tuning |
| `scripts/backfill.sh` | One-time | Process historical runs through feedback pipeline |
| `scripts/install-cron.sh` | One-time | Install/remove cron entries from `config/crontab.txt` |

See [docs/flywheel.md](docs/flywheel.md) for architecture details and [docs/templates-guide.md](docs/templates-guide.md) for the variant lifecycle.

## Dispatch Integration

Learning Loop is designed to be called from `dispatch.sh` immediately after agent completion (after run/result records are written):

```bash
(cd "$WORKSPACE_ROOT" && WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  "$WORKSPACE_ROOT/tools/learning-loop/scripts/feedback-collector.sh" \
  "state/runs/$BEAD_ID.json") || true
```

- Input passed by dispatch: `state/runs/<bead>.json`
- `feedback-collector.sh` resolves this relative path and writes feedback to:
  - `$FEEDBACK_DIR` (if set), otherwise
  - `$WORKSPACE_ROOT/state/feedback` (when `WORKSPACE_ROOT` is set), otherwise
  - `learning-loop/state/feedback`
- Hook is intentionally non-blocking (`|| true`) so dispatch completion is never blocked by feedback processing.

## Goal

Within 50 runs of activation, achieve ≥80% verification-pass rate (up from ~19%).

## Status

See [PRD_LEARNING_LOOP.md](PRD_LEARNING_LOOP.md) for sprint breakdown and task tracking.

## Dependencies

### Beads (bd CLI)

Learning Loop integrates with beads for tracking feedback items and improvement tasks.

- Required version: **0.46.0**
- Fork: [Perttulands/beads](https://github.com/Perttulands/beads) (branch `v0.46.0-stable`)
- Install: `go install github.com/Perttulands/beads/cmd/bd@v0.46.0`
- Verify: `bd --version` should show `bd version 0.46.0`

## Refinement Gating

- `NO_AUTO_PROMOTE` defaults to `true` in `config/env.sh`.
- When a variant wins evaluation, it is queued in `state/scores/promotion-review-queue.json`.
- Use `scripts/ab-tests.sh review-queue` and `scripts/ab-tests.sh approve <template>` for human-gated promotion.
