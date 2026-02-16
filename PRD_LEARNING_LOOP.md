# PRD: Agent Learning Loop

**Status**: IN PROGRESS
**Author**: Athena (PRD Architect)
**Date**: 2026-02-16
**Stakeholder**: Perttu
**Tech Stack**: Bash scripts + JSON state files (reads from `~/.openclaw/workspace/state/`)
**Test Approach**: Each script must be testable standalone

---

## Problem

The agentic coding swarm executes 100+ runs but learns nothing between them. Every dispatch starts from the same baseline prompts. Failures repeat. Template selection is manual guesswork. The system has all the raw material for a learning flywheel — structured run records, verification results, failure reasons, prompt templates — but no closed loop connecting outcomes back to inputs.

**Current baseline** (102 runs): 19% verification pass rate, 7% structured template usage, 50% broken code rate.

**Goal**: Within 50 runs of activation, achieve ≥80% verification-pass rate.

---

## Sprint 1: Foundation
**Status:** IN PROGRESS

Build the feedback loop foundation: every run produces a structured feedback record, outcomes are classified, and patterns are tagged.

- [x] **US-101** Define outcome and feedback JSON schemas
  - Create `config/schemas/feedback.json` and `config/schemas/outcome.json`
  - Outcome types: `full_pass`, `partial_pass`, `agent_failure`, `infra_failure`, `timeout`
  - Feedback record fields: bead, timestamp, template, agent, model, outcome, signals, failure_patterns, prompt_hash
  - Include schema_version field for future migrations

- [x] **US-102** Build feedback-collector.sh
  - Script: `scripts/feedback-collector.sh`
  - Input: run record JSON path + verification JSON path
  - Output: `state/feedback/<bead>.json`
  - Extract signals: exit_clean, tests_pass, lint_pass, ubs_clean, truthsayer_clean, duration_ratio, retried
  - Classify outcome using the 5-category system (full_pass / partial_pass / agent_failure / infra_failure / timeout)
  - Must work standalone: `./scripts/feedback-collector.sh <run-record.json>` with no external deps beyond jq

- [x] **US-103** Build failure pattern detector
  - Detect and tag patterns: test-failure-after-completion, lint-failure-after-completion, scope-creep, incomplete-work, infra-tmux, infra-disk, repeated-failure, verification-gap
  - Detection rules per PRD §4.1 pattern table
  - Integrate into feedback-collector.sh as a function or separate callable script
  - Write pattern occurrences to pattern-registry.json

- [x] **US-104** Build score-templates.sh
  - Script: `scripts/score-templates.sh`
  - Input: all `state/feedback/*.json` files
  - Output: `state/scores/template-scores.json`
  - Composite score: `(full_pass_rate × 1.0) + (partial_pass_rate × 0.4) - (retry_rate × 0.2) - (timeout_rate × 0.3)` clamped [0, 1]
  - Confidence levels: low (<5 runs), medium (5-19), high (≥20)
  - Trend detection: compare last-10 vs all-time, delta thresholds ±0.05
  - Per-agent breakdown within each template

- [x] **US-105** Backfill historical runs
  - Run feedback-collector.sh against all existing ~102 run records in `~/.openclaw/workspace/state/runs/`
  - Generate initial template-scores.json from backfilled data
  - Seed pattern-registry.json with historical patterns
  - Create backfill script: `scripts/backfill.sh` that iterates all runs

- [ ] **US-REVIEW-S1** Review Sprint 1
  - Verify all feedback records generated correctly from sample runs
  - Validate template-scores.json has accurate aggregations
  - Confirm standalone testability of each script
  - Check schema version fields present

---

## Sprint 2: Template Scoring + Selection
**Status:** NOT STARTED

Use accumulated scores to recommend templates and agents for each dispatch.

- [ ] **US-201** Build select-template.sh
  - Script: `scripts/select-template.sh`
  - Input: task description string
  - Output: JSON with template, variant, agent, model, score, confidence, reasoning, warnings
  - Task type classification from keywords: fix/bug→bug-fix, add/create→feature, refactor→refactor, doc→docs, script→script, review→code-review, fallback→custom
  - Score lookup with confidence gating (require ≥ medium)
  - Agent recommendation: pick agent with highest full_pass_rate (min 3 runs)

- [ ] **US-202** Build agent-scores.json aggregation
  - Extend score-templates.sh to also produce `state/scores/agent-scores.json`
  - Per-agent global stats: total runs, pass rate, avg duration, top failure patterns
  - Per-agent per-template breakdown
  - Used by select-template.sh for agent recommendation

- [ ] **US-203** Integration hook for dispatch.sh
  - Add `--auto-select` flag support to dispatch.sh
  - Call select-template.sh with prompt text, use returned template/agent
  - Advisory mode: log recommendation, don't override explicit args
  - Create integration patch file: `scripts/dispatch-integration.patch`

- [ ] **US-204** Validate with 10 test dispatches
  - Run select-template.sh against 10 real task descriptions from history
  - Compare recommendations to what was actually used
  - Document accuracy and edge cases
  - Write validation report to `state/reports/selection-validation.md`

- [ ] **US-REVIEW-S2** Review Sprint 2
  - Verify task classification accuracy on diverse prompts
  - Confirm agent recommendations match score data
  - Test dispatch.sh integration doesn't break existing flow
  - Validate edge cases: no scores, low confidence, missing templates

---

## Sprint 3: Prompt Refinement + A/B Testing
**Status:** NOT STARTED

Templates improve themselves through automated refinement triggered by failure patterns.

- [ ] **US-301** Build refine-prompts.sh
  - Script: `scripts/refine-prompts.sh`
  - Threshold triggers: full_pass_rate < 0.50 (≥10 runs), pattern count ≥ 5, declining trend 2 cycles
  - Apply refinement strategies per failure pattern (PRD §4.4 table)
  - Generate variant: `templates/<name>-vN.md`
  - Support `--auto` flag for cron and `--dry-run` for preview

- [ ] **US-302** Implement A/B test lifecycle
  - Track active tests in `state/scores/ab-tests.json`
  - Alternating dispatch between original and variant (integrate with select-template.sh)
  - After target_runs reached per variant, compare scores
  - Promote if variant > original by ≥ 0.1, otherwise discard
  - Archive originals to `templates/.archive/`
  - Log all decisions in `state/scores/refinement-log.json`

- [ ] **US-303** Wire cron jobs
  - Hourly: score-templates.sh
  - Daily 03:00 UTC: refine-prompts.sh --auto
  - Weekly Sunday 00:00 UTC: weekly-strategy.sh
  - Create `config/crontab.txt` with entries
  - Install script: `scripts/install-cron.sh`

- [ ] **US-304** Build weekly-strategy.sh
  - Script: `scripts/weekly-strategy.sh`
  - Output: `state/reports/strategy-YYYY-WNN.json`
  - Contents: week-over-week trends, agent comparison, top 3 failure patterns, A/B results, recommendations
  - Human-readable summary section for notification

- [ ] **US-REVIEW-S3** Review Sprint 3
  - Verify refinement triggers fire correctly on threshold data
  - Confirm A/B test tracking and promotion logic
  - Test cron schedule doesn't conflict with existing jobs
  - Validate weekly report content and formatting

---

## Sprint 4: Strategy Evolution + Integration + Polish
**Status:** NOT STARTED

The flywheel runs unattended with safety guardrails, notifications, and documentation.

- [ ] **US-401** Notification integration
  - Notify via wake-gateway on: variant created, variant promoted/discarded, score regression, weekly report
  - Message format per PRD §5.3
  - Integrate with existing `wake-gateway.sh`

- [ ] **US-402** Safety guardrails
  - Max 3 active variants per template (oldest discarded if exceeded)
  - Minimum sample size enforcement (no scoring <5, no refinement <10)
  - Auto-rollback: if promoted template scores worse for 10 runs, revert and alert
  - `--no-auto-promote` flag for human-gated promotions
  - Prompt hash tracking to detect retries and avoid double-counting
  - Refinement loop breaker: after 5 refinements without improvement, flag for human review

- [ ] **US-403** Pattern registry management
  - Script: `scripts/manage-patterns.sh`
  - Commands: list, detail <pattern>, mitigate <pattern> <description>, effectiveness <pattern>
  - Track mitigation_effective boolean based on post-mitigation occurrence rate
  - Infra failure isolation: exclude infra patterns from template scoring

- [ ] **US-404** Documentation and integration polish
  - Update `docs/flywheel.md` with learning loop architecture
  - Update `docs/templates-guide.md` with variant lifecycle
  - Update `AGENTS.md` with new scripts and workflow
  - Add learning loop section to workspace README

- [ ] **US-405** Retrospective tooling
  - Script: `scripts/retrospective.sh`
  - Compare pre-loop vs post-loop metrics
  - Generate before/after report on pass rate, template usage, failure patterns
  - Identify threshold tuning opportunities

- [ ] **US-REVIEW-S4** Review Sprint 4
  - End-to-end test: dispatch → verify → feedback → score → select → refine cycle
  - Confirm notifications fire correctly
  - Verify guardrails prevent runaway refinement
  - Documentation review for completeness and accuracy
  - Validate the full flywheel runs unattended for a simulated batch

---

## Metrics & Success Criteria

| Metric | Baseline | 30-Run Target | 100-Run Target |
|---|---|---|---|
| Full verification pass rate | ~19% | ≥ 50% | ≥ 80% |
| Template utilization (non-custom) | 7% | ≥ 30% | ≥ 60% |
| Infra failure rate | 7% | ≤ 5% | ≤ 2% |
| Retry rate | ~10% | ≤ 10% | ≤ 5% |

## Dependencies

- `jq` (installed)
- `verify.sh` (working)
- `prompt-optimizer` skill (working)
- `analyze-runs.sh` (working)
- `wake-gateway.sh` (working)
- `br` / beads (working)
- Cron (available)
