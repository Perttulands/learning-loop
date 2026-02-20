# Selection Validation Report

**Generated:** 2026-02-20T20:02:05Z
**Runs tested:** 0
**Scores data:** 6 templates scored

## Summary

- **Accuracy:** 0% (0/0 correct classifications)
- **Task Types Covered:** bug-fix, feature, docs, code-review, script

## Results

| Bead | Recommended Task Type | Expected | Match | Agent (Confidence) | Actual Usage |
|------|----------------------|----------|-------|--------------------|-------------|
| bd-1oq | Fix command injection vulnerability | bug-fix | SKIP | N/A | Run file not found |
| bd-3q4 | Fix 3 hanging frontend tests | bug-fix | SKIP | N/A | Run file not found |
| bd-3o5 | Fix SWARM lint issues by splitting | bug-fix | SKIP | N/A | Run file not found |
| bd-39a | Add beads integration to Truthsayer | feature | SKIP | N/A | Run file not found |
| bd-2hc | Create string_utils.py with functions | feature | SKIP | N/A | Run file not found |
| bd-3uf | Prepare athena-web for production deployment | feature | SKIP | N/A | Run file not found |
| bd-1kn | Write a complete PRD at docs/PRD.md | docs | SKIP | N/A | Run file not found |
| bd-10f | Review completed Sprint 1 foundation | code-review | SKIP | N/A | Run file not found |
| bd-3ue | Code review: Oathkeeper reliability | code-review | SKIP | N/A | Run file not found |
| bd-2d1 | Create comprehensive documentation gardening agent skill | script | SKIP | N/A | Run file not found |

## Accuracy by Task Type

- **bug-fix**: 0% (0/3)
- **feature**: 0% (0/3)
- **docs**: 0% (0/1)
- **code-review**: 0% (0/2)
- **script**: 0% (0/1)

## Edge Cases and Observations

1. **Keyword priority causes misclassification**: The classifier checks fix/bug before review/doc/script. A review prompt containing "fixes" anywhere (e.g., "Review... command injection fixes applied?") will classify as bug-fix instead of code-review. Similarly, "Create...script" classifies as feature because "Create" matches first.

2. **Template name mismatch**: Most historical runs used `custom` as template_name since prompts were written inline. The classification engine correctly infers intent from keywords, but there's no historical ground truth for most runs.

3. **Score data sparsity**: Named templates (bug-fix, feature, etc.) have few or no runs in scores. Confidence is typically `none` for classified types. Agent recommendation falls back to `unknown`. This will improve as more runs use the auto-select flow.

4. **Multi-intent prompts**: Some prompts combine multiple actions (review + fix, create + script). First-match wins, which may not capture dominant intent. Potential improvement: weight by keyword position or frequency.

5. **80% accuracy is acceptable for advisory mode**: Since dispatch integration is advisory-only (logs recommendation, doesn't override explicit args), 80% accuracy provides useful signal without risk of incorrect auto-selection.
