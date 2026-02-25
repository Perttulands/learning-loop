# Opus Judge Interface Spec

## Purpose

Define a stable interface for qualitative code judging in the learning loop.

- Input: run context + verification metadata + optional diff refs
- Output: normalized quality JSON used by feedback collection

## Invocation

```bash
./scripts/opus-judge.sh <run-record.json>
```

Environment controls:

- `JUDGE_ENABLED` (default: `false`)
- `JUDGE_MODEL` (default: `opus`)
- `JUDGE_TIMEOUT_SECONDS` (default: `60`)
- `JUDGE_MAX_DIFF_LINES` (default: `1200`)
- `JUDGE_SAMPLE_RATE` (default: `0.25`)

## Input Contract

Input schema: `config/schemas/opus-judge-input.json`.

Minimum required field:

- `bead`

Commonly used fields:

- `prompt`, `template`, `agent`, `model`
- `status`, `exit_code`, `verification`
- `repo_path`, `branch`, `base_ref`, `head_ref`

## Output Contract

Output schema: `config/schemas/opus-judge-output.json`.

Required output fields:

- `schema_version`
- `bead`
- `judged_at`
- `judge_model`
- `quality_score` (0-1)
- `style_rating` (1-5)
- `maintainability_rating` (1-5)
- `correctness_rating` (1-5)
- `confidence` (`high|medium|low`)
- `verdict` (`pass|partial|fail`)
- `critique`
- `findings[]`

## Feedback Integration Contract

`feedback-collector.sh` consumes judge output as:

- `opus_quality_score` ← `quality_score`
- `opus_judge.judge_model` ← `judge_model`
- `opus_judge.style_rating` ← `style_rating`
- `opus_judge.maintainability_rating` ← `maintainability_rating`
- `opus_judge.critique` ← `critique`
- `opus_judge.judged_at` ← `judged_at`

## Failure Modes

Judge failures are non-blocking.

- Invalid/missing judge output: skip quality merge, continue feedback write
- Timeout: return non-zero and let caller decide fallback
- Missing diff context: judge still returns output using run metadata only

## Example Output

```json
{
  "schema_version": "1.0.0",
  "bead": "athena-abc",
  "judged_at": "2026-02-20T12:00:00Z",
  "judge_model": "opus",
  "quality_score": 0.74,
  "style_rating": 4,
  "maintainability_rating": 4,
  "correctness_rating": 3,
  "confidence": "medium",
  "verdict": "partial",
  "critique": "Implementation is mostly correct but misses one edge case.",
  "findings": [
    {
      "severity": "major",
      "title": "Missing empty-input handling",
      "details": "Function returns success for invalid empty payload."
    }
  ],
  "input_summary": {
    "diff_lines": 82,
    "tests_status": "pass",
    "lint_status": "pass"
  }
}
```
