# Template Variant Lifecycle

Templates improve automatically through a refinement and A/B testing cycle.

## Scoring

Each template accumulates a composite score from feedback records:

```
score = (full_pass_rate * 1.0) + (partial_pass_rate * 0.4) - (retry_rate * 0.2) - (timeout_rate * 0.3)
```

Clamped to [0, 1]. Infra failures are excluded from scoring.

Confidence levels:
- **Low**: <5 runs (not used for selection)
- **Medium**: 5-19 runs (used with warning)
- **High**: >=20 runs (fully trusted)

## Refinement Triggers

`scripts/refine-prompts.sh` checks three conditions (daily at 03:00 UTC):

1. **Low pass rate**: full_pass_rate < 0.50 with >= 10 runs
2. **Pattern accumulation**: >= 5 failure pattern occurrences
3. **Declining trend**: last-10 score trending down vs all-time

When triggered, the script applies pattern-specific strategies:
- test-failure → add explicit test instructions
- lint-failure → add lint check reminders
- scope-creep → add scope constraints
- incomplete-work → add completion checklist
- repeated-failure → add retry avoidance instructions
- verification-gap → add verification steps

## Variant Creation

Variants are named incrementally: `bug-fix-v1.md`, `bug-fix-v2.md`, etc.

Each variant:
- Copies the original template content
- Appends refinement instructions based on detected failure patterns
- Gets logged in `state/scores/refinement-log.json`

## A/B Testing

`scripts/ab-tests.sh` manages the test lifecycle:

### Create
```bash
ab-tests.sh create <original> <variant> [target_runs]
```
Creates an active test. Default target: 20 runs per variant.

### Pick
```bash
ab-tests.sh pick <original>
```
Returns whichever template has fewer runs (for alternating dispatch). Integrated into `scripts/select-template.sh`.

### Record
```bash
ab-tests.sh record <original> <which>
```
Increments run count for original or variant side.

### Evaluate
```bash
ab-tests.sh evaluate <original>
```
After target runs reached, compares scores from template-scores.json:
- **Promote**: variant score > original score by >= 0.1
- **Discard**: otherwise

## Promotion

When a variant wins:
1. Original archived to `templates/.archive/<original>.md`
2. Variant content replaces original
3. Variant file archived
4. Decision logged to `state/scores/refinement-log.json`
5. Notification sent via `scripts/notify.sh`

## Discard

When a variant loses:
1. Variant archived to `templates/.archive/<variant>.md`
2. Original unchanged
3. Decision logged
4. Notification sent

## Safety Guardrails

- **Max 3 active variants** per template (oldest discarded via `scripts/guardrails.sh`)
- **Auto-rollback**: if promoted template scores worse for 10 consecutive runs, original restored from archive
- **Loop breaker**: after 5 refinements without improvement, template flagged for human review
- **Human gate**: set `NO_AUTO_PROMOTE=true` to require manual promotion approval

## Manual Operations

List active A/B tests:
```bash
ab-tests.sh list
```

View pattern effectiveness:
```bash
manage-patterns.sh effectiveness <pattern>
```

Preview what refinement would do:
```bash
refine-prompts.sh              # preview mode (default)
refine-prompts.sh --dry-run    # show triggers only
refine-prompts.sh --auto       # execute refinement
```
