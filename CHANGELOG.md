# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- LL-019 (`athena-ps3p`): aligned `NO_AUTO_PROMOTE` default to `false` in `ab-tests.sh` and the default unset behavior tests.
- README: restored mythology intro (The Ouroboros), character sigil and visual items, "Part of the Agora" section
- LL-004 (`athena-cm9`): strengthened dispatch auto-select integration patch with variant-aware template resolution, recommendation reasoning logs, and invalid recommendation guards.
- LL-004 (`athena-cm9`): expanded `tests/test-dispatch-integration.sh` assertions for variant handling and recommendation validation behavior.
- LL-005 (`athena-yhs`): added Opus quality placeholders to feedback schema/records (`opus_quality_score`, `opus_judge`) to support qualitative judging.
- LL-005 (`athena-yhs`): updated schema and collector tests to validate new Opus quality fields and null-by-default behavior.
- LL-006 (`athena-77y`): enabled human-gated refinement promotions by default (`NO_AUTO_PROMOTE=true`) with queued review entries and explicit approval flow in `ab-tests.sh`.
- LL-006 (`athena-77y`): added promotion review queue state (`state/scores/promotion-review-queue.json`) and extended A/B lifecycle tests for gated and approved promotions.
- LL-007 (`athena-bc8`): expanded weekly strategy reports with `metrics` and `highlights` sections for system-level run, score, A/B, and refinement visibility.
- LL-007 (`athena-bc8`): added `tests/test-weekly-strategy-metrics.sh` to validate new weekly report metrics calculations and highlight generation.
- LL-008 (`athena-bt3`): wired `refine-prompts.sh --auto` to create an A/B test automatically for each new variant (default target: 10 runs, idempotent by original+variant pair).
- LL-008 (`athena-bt3`): added `tests/test-refine-auto-ab.sh` to verify variant generation and automatic A/B test creation behavior.
- LL-009 (`athena-5bw`): extended dispatch integration patch to record A/B test runs via `ab-tests.sh record`, including variant-to-original normalization.
- LL-009 (`athena-5bw`): expanded dispatch integration tests to assert A/B tracking hooks and variant side detection logic.
- LL-010 (`athena-qkp`): added formal Opus judge interface spec (`docs/opus-judge-spec.md`) with invocation contract, schema mapping, failure modes, and example output.
- LL-010 (`athena-qkp`): added judge input/output schema files and validation test coverage (`tests/test-opus-judge-spec.sh`).
- LL-011 (`athena-64l`): implemented `scripts/opus-judge.sh` to emit structured qualitative judgment JSON (quality score, ratings, verdict, critique, findings) from run records.
- LL-011 (`athena-64l`): added `tests/test-opus-judge.sh` and documented `opus-judge.sh` in README/AGENTS script inventories.
- LL-012 (`athena-bnw`): integrated sampled Opus judging into `feedback-collector.sh`, populating `opus_quality_score` and enriched `opus_judge` fields when judge output is available.
- LL-012 (`athena-bnw`): extended feedback collector tests with mock judge coverage for sampled and non-sampled paths.
- LL-013 (`athena-2kq`): updated weekly strategy cron scheduling to Sunday 07:00 UTC in `config/crontab.txt`.
- LL-013 (`athena-2kq`): updated cron installer tests to validate the new weekly schedule.
- LL-014 (`athena-r3b`): added `agent_recommendations` to weekly strategy reports with per-agent strengths, weaknesses, and targeted recommendation text.
- LL-014 (`athena-r3b`): added `tests/test-weekly-agent-recommendations.sh` to validate recommendation generation from per-template agent scores.
- LL-015 (`athena-3bh`): replaced keyword-only task classification with weighted structure-aware pattern scoring in `select-template.sh`.
- LL-015 (`athena-3bh`): added `tests/test-task-classification.sh` with 58 labeled prompts and enforced >=90% classification accuracy.
- LL-015 (`athena-3bh`): hardened selection validation reporting to emit SKIP rows when historical run directories are unavailable.
- LL-016 (`athena-esi`): added `scripts/dashboard.sh` to generate `state/reports/dashboard.html` with template/agent scores, A/B status, and weekly recommendations.
- LL-016 (`athena-esi`): scheduled dashboard generation in cron and added `tests/test-dashboard.sh` coverage for dashboard output.
- LL-016 (`athena-esi`): expanded README loop quick reference entries for all four feedback loops.
- LL-017 (`athena-059`): added `scripts/guardrail-audit.sh` to run guardrail smoke checks and emit `guardrail-audit-*.json` reports.
- LL-017 (`athena-059`): added `tests/test-guardrail-audit.sh` and documented guardrail audit tooling in AGENTS/README.
- LL-018 (`athena-54j`): added `scripts/backup-state.sh` with `backup`, `list`, and `restore` commands plus 30-day retention cleanup.
- LL-018 (`athena-54j`): added daily backup cron scheduling and `tests/test-backup-state.sh` coverage for backup creation, restore, and retention behavior.
