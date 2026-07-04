---
name: mstack-code-review
description: |
  Code review with configurable depth. Default: 1 unified reviewer covering
  correctness, conventions, and simplicity. Adversarial mode (plan frontmatter
  `review: adversarial`): standard reviewer + adversarial reviewer that hunts
  for production failure modes. Thorough mode (`review: thorough`): 3 blind
  reviewers with cross-model routing. Routes through external models when
  available. Discards low-confidence findings.

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

You run a structured code review with optional cross-model verification.

**Default mode (standard):** 1 reviewer covers correctness, conventions, and
simplicity in a single pass. Fast, cost-effective, sufficient for most plans.

**Adversarial mode:** Standard reviewer + an adversarial reviewer that tries
to break the code. Activated with `review: adversarial` in plan frontmatter.
Use for high-stakes plans where a missed bug is expensive: auth, payments,
data migrations, public APIs.

**Thorough mode:** 3 independent blind reviewers (correctness, conventions,
simplicity) with cross-model routing. Activated when the plan's frontmatter
has `review: thorough`. The architect decides review depth at plan time.

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

## Discovery: check for external models

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

## Step 1: Determine diff scope

- **Called by mstack-run**: review the uncommitted diff (`git diff`)
- **Called with file path**: review that file's diff against HEAD
- **Called with no args**: review uncommitted changes (`git diff` + `git diff --cached`)
- **Called with plan ID**: review changes from that plan's implementation

```bash
git diff --stat
```

If diff is empty, check cached changes. If still empty: "Nothing to review."

## Step 2: Run review

Check the plan's frontmatter for `review: adversarial` or `review: thorough`.
If not set, use standard mode.

### Standard mode (default): single unified reviewer

One reviewer covers all three dimensions in a single pass:

> Review this diff for correctness, conventions, and simplicity.
>
> **Correctness:** Does it satisfy the requirements? Logic errors, missing
> edge cases, null/undefined paths, error handling gaps?
>
> **Conventions:** Does it follow `AGENTS.md`/`CLAUDE.md` rules, naming patterns, import
> style, error handling approach of the surrounding codebase?
>
> **Simplicity:** Over-engineering? Duplicated logic? Unnecessary abstractions?
>
> Score each finding 1-10 for confidence. Only report findings >= 7.
> Format: one line per issue with file:line, severity (critical/high/medium),
> confidence score, and dimension (correctness/conventions/simplicity).

If an external model is available (codex/gemini), route the single
reviewer through it for generator/judge separation. Otherwise run as
Claude.

### Adversarial mode (`review: adversarial`): standard + adversarial reviewer

Runs the standard reviewer above, PLUS a second independent reviewer
with an adversarial prompt. The adversarial reviewer works blind; it
does not see the standard reviewer's findings.

The adversarial reviewer gets this prompt:

> Your job is to find ways this code will fail in production. Think like
> an attacker and a chaos engineer combined.
>
> Hunt specifically for:
> - **Race conditions and concurrency bugs**: shared state, missing locks,
>   TOCTOU windows, async ordering assumptions
> - **Security holes**: injection vectors, auth bypasses, privilege
>   escalation, data exposure, timing attacks
> - **Resource leaks**: unclosed handles, unbounded growth, missing
>   cleanup on error paths
> - **Silent data corruption**: lossy conversions, truncation without
>   error, partial writes that look successful
> - **Failure mode blindness**: what happens when the network is slow,
>   the disk is full, the dependency is down, the input is 10x expected size
>
> No compliments. No "looks good overall." Just the problems.
> Score each finding 1-10 for confidence. Only report findings >= 7.
> Format: one line per issue with file:line, severity (critical/high/medium),
> confidence score, and dimension (adversarial).

Route the adversarial reviewer through an external model if available
(codex/gemini) for genuine perspective diversity. If unavailable, run as
a Claude agent; prompt framing still surfaces different findings than
the standard pass.

Merge findings from both reviewers using the same dedup logic as
thorough mode (Step 3).

### Thorough mode (`review: thorough`): 3 blind reviewers

Spawn 3 independent review agents. They score findings 1-10 independently
and blind (they cannot see each other's output):

1. **Correctness**: logic errors, missing edge cases, acceptance criteria
2. **Conventions**: naming, imports, error handling, `AGENTS.md`/`CLAUDE.md` rules
3. **Simplicity**: over-engineering, duplication, unnecessary abstractions

Route one reviewer through the best available external model
(generator/judge separation). If no external model is available, all three
run as Claude agents.

## Step 3: Merge and filter findings

After all 3 agents return:

1. Collect all findings
2. Discard anything below confidence 7
3. Deduplicate (same file:line from multiple reviewers = merge, take highest severity)
4. Sort by severity: critical > high > medium

## Step 4: Act on findings

For each finding:

- **Critical**: fix immediately (bugs or security issues)
- **High**: fix (real quality problems)
- **Medium**: fix if trivial (< 2 edits), otherwise note in commit message

After applying fixes, re-run the verification gate (mstack-code-health logic)
to confirm nothing broke. If the gate fails, revert the review-inspired changes
and proceed with the original passing implementation.

## Step 4b: Simplification pass

After fixing review findings, run a quick simplification pass on the
changed files (this subsumes the standalone mstack-simplify-code skill).

For each file in the diff, check for:
- **Reuse opportunities**: duplicate logic that an existing utility handles
- **Clarity issues**: unnecessary nesting, overly generic names, dead code
- **Consistency**: import style, naming conventions, error handling patterns
- **Efficiency**: obvious N+1 patterns, unnecessary re-computation

Apply simplifications surgically. Re-run the verification gate after.
If the gate fails, revert the simplifications and keep the review-fixed
version.

This pass is lightweight: it only looks at files already in the diff,
not the whole codebase. It catches low-hanging fruit that the narrow
review agents (correctness, conventions, simplicity) miss because they
focus on bugs, not polish.

## Step 5: Write review artifact

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
  "providers": ["claude", "codex"],
  "mode": "adversarial",
  "findings_total": 5,
  "findings_above_threshold": 3,
  "findings_fixed": 2,
  "findings_noted": 1,
  "reviewers": {
    "standard": { "provider": "claude", "findings": 2 },
    "adversarial": { "provider": "codex", "findings": 1 }
  }
}
```

## Step 5b: Record the code gate verdict

Only when this run has plan context (a `PLAN_ID` is known): record the
`code` review outcome so the completion gate can read it. Run
`review-gate.sh record <plan> code pass|fail`. This is the **only** way the
`code` gate clears — a review that finishes without this step, or that
never runs, leaves the gate OPEN.

```bash
RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$RUN_SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
done
# shellcheck source=skills/mstack-run/scripts/lib.sh
. "$RUN_SKILL_DIR/scripts/lib.sh"

ARTIFACT="$REPO_ROOT/.mstack/reviews/plan-${PLAN_ID}.json"
VERDICT="$(code_verdict_from_findings "$ARTIFACT")"
bash "$RUN_SKILL_DIR/scripts/review-gate.sh" record "${PLAN_ID}" code "$VERDICT" mstack-code-review
```

`code_verdict_from_findings` (`lib.sh`) is the one sanctioned mapping from the
`findings_above_threshold`/`findings_fixed` counters above to a verdict (the
034 fail condition): any critical/high finding still unfixed after this
review's Step 4 → `fail`; otherwise → `pass`. Do not compute this mapping
any other way. If there is no `PLAN_ID` (a standalone review with no plan
context), there is no gate to record against — skip this step.

## Step 6: Report

```
CODE REVIEW SUMMARY
===================
Mode: adversarial
Reviewers: Claude (standard) + Codex (adversarial)
Findings: 5 total, 3 above threshold (confidence >= 7)
  Fixed:  2 (1 critical, 1 high)
  Noted:  1 medium (see commit message body)

Fixed findings:
  [CRITICAL] src/api/handler.ts:42: SQL injection via unsanitized input (standard, confidence 9)
  [HIGH]     src/lib/queue.ts:78: unbounded retry loop under sustained 429s (adversarial, confidence 8)

Noted (medium, in commit message):
  [MEDIUM]   src/api/handler.ts:55: could use existing validate() utility (standard, confidence 7)

Gate after fixes: PASS
```

## Integration with mstack-run

When called by the worker at Step 6, return a structured result:

```
REVIEW COMPLETE
MODE: adversarial
FINDINGS_FIXED: 2
FINDINGS_NOTED: 1
GATE_AFTER_FIXES: PASS
```

The worker incorporates noted findings into the commit message body.
