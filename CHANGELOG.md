# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
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
