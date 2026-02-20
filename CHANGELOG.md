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
