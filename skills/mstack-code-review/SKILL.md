---
name: mstack-code-review
description: |
  Cross-model code review with blind scoring. Spawns 3 review agents in
  parallel (correctness, conventions, simplicity), each scoring independently.
  Routes one reviewer through an external model when available (generator/judge
  separation). Discards low-confidence findings. Writes review artifact to
  .mstack/reviews/.

  Called by mstack-run automatically at Step 6. Also callable standalone
  to review uncommitted changes or a specific diff.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
---

You run a structured, blind code review with optional cross-model verification.
Three independent reviewers examine the diff. Blind scoring eliminates groupthink.
Cross-model review catches what self-review misses.

User input (optional scope):

```
$ARGUMENTS
```

## Hard rules

- **Blind scoring.** Each reviewer works independently. They do not see
  each other's findings until all three return.
- **Confidence gate.** Discard any finding below confidence 7/10.
- **Fix critical/high only.** Medium findings go in the commit message body
  as known improvement opportunities.
- **One review cycle.** Do not re-run reviewers after applying their feedback.
- **Never push.** Review artifacts stay local.

## Discovery — check for external models

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
command -v gemini >/dev/null 2>&1 && echo "GEMINI: available" || echo "GEMINI: unavailable"
[ -f ~/.config/skillshare/skills/codex/SKILL.md ] && echo "GSTACK_CODEX: available" || echo "GSTACK_CODEX: unavailable"
```

Log what's available. Pick the best external model for one reviewer:
1. `codex` binary → route one reviewer through Codex CLI
2. `gemini` binary → route one reviewer through Gemini CLI
3. gstack /codex skill → use that for one reviewer
4. Nothing → all-Claude (still valuable, blind scoring still eliminates groupthink)

Read `.mstack/config.json` for `review.provider` preference if configured.

## Step 1 — Determine diff scope

- **Called by mstack-run**: review the uncommitted diff (`git diff`)
- **Called with file path**: review that file's diff against HEAD
- **Called with no args**: review uncommitted changes (`git diff` + `git diff --cached`)
- **Called with plan ID**: review changes from that plan's implementation

```bash
git diff --stat
```

If diff is empty, check cached changes. If still empty: "Nothing to review."

## Step 2 — Spawn 3 review agents in parallel

Each agent receives the diff and a narrow brief. They score findings 1-10
independently and blind (they cannot see each other's output).

### Agent 1: Correctness

> Review this diff against the plan's acceptance criteria (if available). Check:
> - Does the implementation satisfy the requirements?
> - Are there logic errors, off-by-one bugs, or missing edge cases?
> - Are there null/undefined paths that could crash at runtime?
> - Do error paths handle failures gracefully?
>
> Score each finding 1-10 for confidence. Only report findings >= 7.
> Format: one line per issue with file:line, severity (critical/high/medium),
> and confidence score.

### Agent 2: Conventions

> Review this diff against the project's CLAUDE.md and surrounding code. Check:
> - Does it follow the project's naming conventions?
> - Does it use the established error handling patterns?
> - Does it match the import style and file structure of siblings?
> - Are there project-specific rules being violated?
>
> Score each finding 1-10 for confidence. Only report findings >= 7.
> Format: one line per issue with file:line, severity (critical/high/medium),
> and confidence score.

### Agent 3: Simplicity

> Review this diff for unnecessary complexity. Check:
> - Is anything over-engineered for what's required?
> - Is there duplicated logic that an existing utility handles?
> - Are there unnecessary abstractions or indirection layers?
> - Could any section be simplified without losing functionality?
>
> Score each finding 1-10 for confidence. Only report findings >= 7.
> Format: one line per issue with file:line, severity (critical/high/medium),
> and confidence score.

Route one of these agents through the best available external model
(generator/judge separation). If no external model is available, all three
run as Claude agents.

## Step 3 — Merge and filter findings

After all 3 agents return:

1. Collect all findings
2. Discard anything below confidence 7
3. Deduplicate (same file:line from multiple reviewers = merge, take highest severity)
4. Sort by severity: critical > high > medium

## Step 4 — Act on findings

For each finding:

- **Critical**: fix immediately — bugs or security issues
- **High**: fix — real quality problems
- **Medium**: fix if trivial (< 2 edits), otherwise note in commit message

After applying fixes, re-run the verification gate (mstack-code-health logic)
to confirm nothing broke. If the gate fails, revert the review-inspired changes
and proceed with the original passing implementation.

## Step 5 — Write review artifact

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$REPO_ROOT/.mstack/reviews"
```

Write to `$REPO_ROOT/.mstack/reviews/plan-${PLAN_ID}.json` (or
`review-${TIMESTAMP}.json` if no plan context):

```json
{
  "ts": "2026-05-19T14:30:00Z",
  "plan_id": "042",
  "commit": "abc1234",
  "providers": ["claude", "claude", "codex"],
  "findings_total": 5,
  "findings_above_threshold": 3,
  "findings_fixed": 2,
  "findings_noted": 1,
  "reviewers": {
    "correctness": { "provider": "claude", "findings": 1 },
    "conventions": { "provider": "claude", "findings": 1 },
    "simplicity": { "provider": "codex", "findings": 1 }
  }
}
```

## Step 6 — Report

```
CODE REVIEW SUMMARY
===================
Reviewers: Claude (correctness, conventions) + Codex (simplicity)
Findings: 5 total, 3 above threshold (confidence >= 7)
  Fixed:  2 (1 critical, 1 high)
  Noted:  1 medium — see commit message body

Fixed findings:
  [CRITICAL] src/api/handler.ts:42 — SQL injection via unsanitized input (correctness, confidence 9)
  [HIGH]     src/lib/parse.ts:18 — missing null check on optional field (correctness, confidence 8)

Noted (medium, in commit message):
  [MEDIUM]   src/api/handler.ts:55 — could use existing validate() utility (simplicity, confidence 7)

Gate after fixes: PASS
```

## Integration with mstack-run

When called by the worker at Step 6, return a structured result:

```
REVIEW COMPLETE
FINDINGS_FIXED: 2
FINDINGS_NOTED: 1
GATE_AFTER_FIXES: PASS
```

The worker incorporates noted findings into the commit message body.
