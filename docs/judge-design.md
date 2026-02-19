# Learning Loop Judge — Design Doc

## Problem

The current feedback-collector is mechanical: it reads exit codes, test results, and lint status from run records. It answers "did the checks pass?" but not "is the code actually good?"

Mechanical signals miss:
- **Code quality** — does the diff make sense, or did the agent brute-force tests to pass?
- **Scope adherence** — did the agent do what was asked, or wander?
- **Architectural fit** — does the change follow project patterns?
- **Incomplete work** — agent exited clean but left TODOs, stubs, or commented-out code
- **False passes** — tests pass but the implementation is wrong or fragile

## Solution: Opus Judge

A Claude Code instance running Opus reviews every completed run. It reads the actual artifacts — the diff, test output, prompt, and run context — and produces a structured judgment.

### Architecture

```
Run completes
    │
    ▼
feedback-collector.sh          ← mechanical signals (unchanged)
    │
    ▼
judge.sh <run-record.json>     ← NEW: Opus evaluation
    │
    ├── reads: git diff, test output, lint output, original prompt
    ├── invokes: claude --model opus (one-shot, no conversation)
    └── writes: state/judgments/<bead>.json
    │
    ▼
feedback-collector.sh merges   ← combines mechanical + judgment
    │
    ▼
state/feedback/<bead>.json     ← enriched record
```

### What the Judge Sees

For each run, `judge.sh` assembles a context package:

1. **Original prompt** — what the agent was asked to do
2. **Git diff** — what actually changed (`git diff main...<branch>`)
3. **Test output** — stdout/stderr from test run (truncated to 2000 lines)
4. **Lint output** — if available
5. **Run metadata** — agent, model, template, duration, exit code

### What the Judge Returns

Structured JSON with:

```json
{
  "schema_version": "1.0.0",
  "bead": "bd-xxx",
  "verdict": "pass" | "partial" | "fail",
  "score": 0.0-1.0,
  "dimensions": {
    "correctness": 0.0-1.0,
    "scope_adherence": 0.0-1.0,
    "code_quality": 0.0-1.0,
    "completeness": 0.0-1.0
  },
  "issues": [
    { "severity": "major" | "minor", "description": "..." }
  ],
  "summary": "One paragraph assessment",
  "confidence": "high" | "medium" | "low"
}
```

### Scoring Dimensions

| Dimension | What it measures |
|-----------|-----------------|
| **correctness** | Does the code do what was asked? Do tests actually test the right thing? |
| **scope_adherence** | Did the agent stay on task? No unrelated changes, no gold-plating? |
| **code_quality** | Follows project patterns? Clean, readable, no hacks? |
| **completeness** | No stubs, TODOs, commented-out code, missing edge cases? |

Composite score: weighted average. Default weights: correctness 0.4, scope 0.2, quality 0.2, completeness 0.2.

### Integration with Existing Pipeline

The mechanical signals stay. They're fast, free, and catch the obvious stuff. The judge layer adds depth:

```
outcome (existing)     → full_pass, partial_pass, agent_failure, ...
judgment (new)         → { verdict, score, dimensions, issues }
```

Template scoring (`score-templates.sh`) gains a new input:
- Current: composite from pass rates + retry + timeout penalties
- New: blended with judge scores (e.g., `0.6 * mechanical + 0.4 * judge_avg`)

### Invocation

```bash
# One-shot judge call
claude --model opus --print \
  --system-prompt "$(cat config/judge-prompt.md)" \
  "$(cat /tmp/judge-context-<bead>.txt)" \
  > state/judgments/<bead>.json
```

Flags:
- `--print` — no conversation, just output
- `--model opus` — non-negotiable, this is the quality gate
- Context assembled as a single text block (prompt + diff + test output)

### Judge Prompt

Lives at `config/judge-prompt.md`. Core instructions:

1. You are a code review judge. Be harsh but fair.
2. Score each dimension 0.0-1.0. Don't grade on a curve.
3. A "pass" verdict requires all dimensions ≥ 0.7.
4. Flag any test that looks like it was written to pass rather than to verify.
5. Flag scope creep (changes unrelated to the prompt).
6. Output valid JSON only. No commentary outside the JSON block.

### Cost & Performance

- **Cost**: ~$0.05-0.15 per judgment (depends on diff size)
- **Latency**: 10-30 seconds per run
- **When to skip**: infra_failure and timeout runs (nothing to judge)
- **Throttle**: max 20 judgments/hour to avoid runaway costs

### Guardrails

- Judge failures don't block the pipeline — mechanical feedback still records
- `JUDGE_ENABLED=true|false` env var (default: false until tested)
- `JUDGE_MODEL` env var (default: opus, overridable for testing)
- Judge output validated against schema before merge
- If judge returns invalid JSON, log warning and skip

### Migration Path

1. **Phase 1**: `judge.sh` runs standalone, writes to `state/judgments/`. No pipeline integration. Manual review of judgment quality.
2. **Phase 2**: `feedback-collector.sh` reads judgment if available, merges into feedback record. Scoring still uses mechanical signals only.
3. **Phase 3**: `score-templates.sh` blends judge scores into composite. A/B test the blended scoring vs mechanical-only.
4. **Phase 4**: Judge scores influence template selection and refinement triggers.

### File Changes

| File | Change |
|------|--------|
| `scripts/judge.sh` | NEW — assembles context, invokes claude, writes judgment |
| `config/judge-prompt.md` | NEW — system prompt for the judge |
| `scripts/feedback-collector.sh` | Phase 2: read + merge judgment if exists |
| `scripts/score-templates.sh` | Phase 3: blend judge scores |
| `state/judgments/` | NEW directory for judgment records |
| `AGENTS.md` | Add judge to script table |
| `CHANGELOG.md` | Entry for each phase |

### Open Questions

- Should the judge see previous feedback for the same template (to catch recurring issues)?
- Should low judge scores trigger immediate re-dispatch vs waiting for pattern detection?
- Diff size limit — truncate at what threshold? (8K tokens suggested)
