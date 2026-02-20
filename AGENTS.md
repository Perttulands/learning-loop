# AGENTS.md - Learning Loop

## Project Overview

Bash + jq + JSON state files. All scripts are standalone executables. Tests use `set -euo pipefail` with inline assertion helpers.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/feedback-collector.sh` | Classify run outcomes, extract signals, write feedback records |
| `scripts/opus-judge.sh` | Produce qualitative Opus-style quality assessment JSON for a run |
| `scripts/detect-patterns.sh` | Detect failure patterns from run records, update registry |
| `scripts/score-templates.sh` | Aggregate feedback into template and agent scores |
| `scripts/select-template.sh` | Recommend template + agent for a task description |
| `scripts/refine-prompts.sh` | Generate improved template variants from failure data and auto-create A/B tests |
| `scripts/ab-tests.sh` | A/B test lifecycle: create, pick, record, evaluate, review queue, approve |
| `scripts/guardrails.sh` | Safety limits: variant caps, rollback, loop breaker |
| `scripts/notify.sh` | Send notifications via wake-gateway |
| `scripts/manage-patterns.sh` | Pattern registry: list, detail, mitigate, effectiveness |
| `scripts/weekly-strategy.sh` | Weekly cross-cutting strategy report |
| `scripts/backfill.sh` | Process historical runs through the feedback pipeline |
| `scripts/install-cron.sh` | Install/remove cron entries for scheduled execution |
| `scripts/retrospective.sh` | Compare pre-loop vs post-loop metrics, suggest threshold tuning |
| `scripts/validate-selection.sh` | Validate template selection against real task history |

## State Files

| Path | Content |
|------|---------|
| `state/feedback/<bead>.json` | Per-run feedback record |
| `state/feedback/pattern-registry.json` | Failure pattern counts and metadata |
| `state/scores/template-scores.json` | Per-template composite scores |
| `state/scores/agent-scores.json` | Per-agent global and per-template stats |
| `state/scores/ab-tests.json` | Active A/B test state |
| `state/scores/promotion-review-queue.json` | Human review queue for gated promotions |
| `state/scores/refinement-log.json` | All refinement and A/B decisions |
| `state/reports/strategy-YYYY-WNN.json` | Weekly strategy reports |

## Environment Variables

All scripts use env vars for testability:
- `FEEDBACK_DIR` — feedback record directory (default: `state/feedback/`)
- `SCORES_DIR` — scores output directory (default: `state/scores/`)
- `REGISTRY_FILE` — pattern registry path (default: `state/feedback/pattern-registry.json`)
- `TEMPLATES_DIR` — template directory (default: `templates/`)
- `REFINEMENT_LOG` — refinement log path (default: `state/scores/refinement-log.json`)
- `REPORTS_DIR` — reports output directory (default: `state/reports/`)
- `WAKE_GATEWAY` — path to wake-gateway.sh
- `NOTIFY_ENABLED` — set to `false` to suppress notifications
- `NO_AUTO_PROMOTE` — defaults to `true` (human-gated A/B promotions)

## Testing Conventions

- Each script has a matching `tests/test-<name>.sh`
- Tests are standalone: `bash tests/test-foo.sh`
- All tests use `set -euo pipefail` with temp dirs for isolation
- Use `FEEDBACK_DIR`, `SCORES_DIR`, etc. to point at test fixtures
- Assertion pattern: `assert "description" "[ condition ]"` with pass/fail counters
- Avoid `((VAR++))` under `set -e` — use `VAR=$((VAR + 1))` instead

## Patterns

- **Single jq pipeline**: prefer one large jq invocation over multiple passes through data
- **Filter by schema fields**: when mixing JSON file types in a directory, use `select(.field != null)` to avoid processing wrong files
- **Env var overrides**: every path should be overridable for test isolation
- **Notifications never crash**: always call notify.sh with `|| true` fallback
- **Marker-based crontab**: each cron line gets a comment marker for idempotent install/remove
