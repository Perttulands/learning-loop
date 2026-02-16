# Selection Validation Report

**Generated:** 2026-02-16T06:36:58Z
**Runs tested:** 10
**Scores data:** 6 templates scored

## Summary

- **Accuracy:** 80% (8/10 correct classifications)
- **Task Types Covered:** bug-fix, feature, docs, code-review, script

## Results

| Bead | Recommended Task Type | Expected | Match | Agent (Confidence) | Actual Usage |
|------|----------------------|----------|-------|--------------------|-------------|
| bd-1oq | bug-fix | bug-fix | YES | unknown (none) | Was: custom/claude/sonnet |
| bd-3q4 | bug-fix | bug-fix | YES | unknown (none) | Was: custom/codex/gpt-5.3-codex |
| bd-3o5 | bug-fix | bug-fix | YES | unknown (none) | Was: custom/claude/sonnet |
| bd-39a | feature | feature | YES | unknown (low) | Was: custom/codex/gpt-5.3-codex |
| bd-2hc | feature | feature | YES | unknown (low) | Was: custom/claude/sonnet |
| bd-3uf | feature | feature | YES | unknown (low) | Was: feature/claude/sonnet |
| bd-1kn | docs | docs | YES | unknown (none) | Was: custom/claude/opus |
| bd-10f | bug-fix | code-review | NO | unknown (none) | Was: code-review/claude/sonnet |
| bd-3ue | code-review | code-review | YES | unknown (low) | Was: custom/codex/gpt-5.3-codex |
| bd-2d1 | feature | script | NO | unknown (low) | Was: script/claude/sonnet |

## Accuracy by Task Type

- **bug-fix**: 100% (3/3)
- **feature**: 100% (3/3)
- **docs**: 100% (1/1)
- **code-review**: 50% (1/2)
- **script**: 0% (0/1)

## Edge Cases and Observations

1. **Keyword priority causes misclassification**: The classifier checks fix/bug before review/doc/script. A review prompt containing "fixes" anywhere (e.g., "Review... command injection fixes applied?") will classify as bug-fix instead of code-review. Similarly, "Create...script" classifies as feature because "Create" matches first.

2. **Template name mismatch**: Most historical runs used `custom` as template_name since prompts were written inline. The classification engine correctly infers intent from keywords, but there's no historical ground truth for most runs.

3. **Score data sparsity**: Named templates (bug-fix, feature, etc.) have few or no runs in scores. Confidence is typically `none` for classified types. Agent recommendation falls back to `unknown`. This will improve as more runs use the auto-select flow.

4. **Multi-intent prompts**: Some prompts combine multiple actions (review + fix, create + script). First-match wins, which may not capture dominant intent. Potential improvement: weight by keyword position or frequency.

5. **80% accuracy is acceptable for advisory mode**: Since dispatch integration is advisory-only (logs recommendation, doesn't override explicit args), 80% accuracy provides useful signal without risk of incorrect auto-selection.
