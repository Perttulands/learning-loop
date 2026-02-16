# Learning Loop Architecture

The learning loop is a closed feedback system that turns every agent run into data that improves future runs.

## Flywheel

```
Dispatch → Execute → Verify → Record → Analyze → Score → Select → Refine → Dispatch
    ^                                                                          |
    └──────────────────────────────────────────────────────────────────────────┘
```

## Four Nested Loops

### 1. Run Feedback (per-run)

`scripts/feedback-collector.sh` processes each completed run:
- Extracts signals (exit_clean, tests_pass, lint_pass, ubs_clean, truthsayer_clean, duration_ratio, retried)
- Classifies outcome into 5 categories: full_pass, partial_pass, agent_failure, infra_failure, timeout
- Detects failure patterns via `scripts/detect-patterns.sh`
- Writes structured record to `state/feedback/<bead>.json`

### 2. Template Scoring (hourly via cron)

`scripts/score-templates.sh` aggregates all feedback records:
- Computes composite score per template: `(full_pass_rate * 1.0) + (partial_pass_rate * 0.4) - (retry_rate * 0.2) - (timeout_rate * 0.3)`, clamped [0, 1]
- Confidence levels: low (<5 runs), medium (5-19), high (>=20)
- Trend detection: last-10 vs all-time with +-0.05 threshold
- Per-agent breakdown within each template
- Outputs `state/scores/template-scores.json` and `state/scores/agent-scores.json`
- Detects score regression (>0.1 drop) and notifies via `scripts/notify.sh`

### 3. Prompt Refinement (daily via cron)

`scripts/refine-prompts.sh` identifies underperforming templates and generates variants:
- Triggers: full_pass_rate < 0.50 (>=10 runs), pattern count >= 5, declining trend
- Applies pattern-specific strategies (test instructions, lint checks, scope limits, etc.)
- Creates variant files: `templates/<name>-vN.md`
- Logs decisions to `state/scores/refinement-log.json`

`scripts/ab-tests.sh` manages the variant lifecycle:
- Alternating dispatch between original and variant
- Promotes variant if score exceeds original by >= 0.1
- Discards variant otherwise
- Archives to `templates/.archive/`

### 4. Strategy Evolution (weekly via cron)

`scripts/weekly-strategy.sh` produces a cross-cutting report:
- Template trends, agent comparison, top failure patterns
- A/B test results, refinement activity
- Auto-generated recommendations
- Output: `state/reports/strategy-YYYY-WNN.json`

## Template Selection

`scripts/select-template.sh` recommends template + agent for each dispatch:
- Classifies task type from keywords (fix/bug, add/create, refactor, doc, script, review)
- Looks up scores with confidence gating
- Picks agent with highest full_pass_rate (min 3 runs)
- Checks for active A/B tests
- Integrates into dispatch.sh via `scripts/dispatch-integration.patch`

## Safety Guardrails

`scripts/guardrails.sh` prevents runaway automation:
- Max 3 active variants per template
- Minimum sample sizes (5 for scoring, 10 for refinement)
- Auto-rollback if promoted template regresses for 10 runs
- `NO_AUTO_PROMOTE` for human-gated promotions
- Prompt hash dedup tracking
- Refinement loop breaker after 5 attempts without improvement

## Notifications

`scripts/notify.sh` sends alerts via wake-gateway on:
- Variant created, promoted, or discarded
- Score regression detected
- Weekly report generated

## Data Flow

```
~/.openclaw/workspace/state/runs/*.json
        |
        v
feedback-collector.sh + detect-patterns.sh
        |
        v
state/feedback/<bead>.json + state/feedback/pattern-registry.json
        |
        v
score-templates.sh
        |
        v
state/scores/template-scores.json + state/scores/agent-scores.json
        |
        v
select-template.sh ──→ dispatch.sh (via --auto-select)
        |
        v
refine-prompts.sh ──→ ab-tests.sh ──→ state/scores/ab-tests.json
        |
        v
weekly-strategy.sh ──→ state/reports/strategy-YYYY-WNN.json
```
