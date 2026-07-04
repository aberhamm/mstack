# Step 6: Code review (mstack-code-review)

After the cleanup sweep (Step 5c) completes, run a structured code review
using mstack-code-review logic.

## Discovery: external models

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
command -v gemini >/dev/null 2>&1 && echo "GEMINI: available" || echo "GEMINI: unavailable"
```

Read `.mstack/config.json` `review.provider` for preference. Pick the
best available external model for one reviewer (codex > gemini > claude-only).

## Run review (configurable depth)

Check the plan's `review` frontmatter field:
- **Standard** (default, or `review` field absent): 1 unified reviewer
  covering correctness, conventions, and simplicity in one pass. Route
  through external model if available.
- **Thorough** (`review: thorough`): 3 blind review agents (correctness,
  conventions, simplicity), each scoring independently. Route one through
  external model for generator/judge separation.

## Filter and act

1. Discard findings below confidence 7
2. Deduplicate (same file:line from multiple reviewers)
3. **Critical/High**: fix immediately
4. **Medium**: fix if trivial (< 2 edits), otherwise note in commit message

After applying fixes, re-run the health gate (Step 5) to confirm nothing
broke. If the gate fails, revert the review-inspired changes and proceed
with the original passing implementation.

One review cycle only. Do not re-run reviewers after applying feedback.

**Progress:** After the review completes and fixes are applied, print:
```
[mstack] ├─ Code review: <N> findings, <N> fixed
```
where the first N is total findings above confidence 7, and the second N
is findings that were actually fixed. If no findings: "0 findings, 0 fixed".

## Write review artifact

```bash
mkdir -p "$REPO_ROOT/.mstack/reviews"
```

Write to `$REPO_ROOT/.mstack/reviews/plan-${PLAN_ID}.json` with findings
count, providers used, and fixes applied. See mstack-code-review for schema.

## Record the code gate verdict

This artifact is a derived cache, not the gate's source of truth. Per
mstack-code-review Step 5b, this review must also run
`review-gate.sh record "$NEXT" code pass|fail` (verdict from
`code_verdict_from_findings` in `lib.sh`) so the `code` entry in the plan's
`reviews:` frontmatter block is up to date. Step 7a's
`review-gate.sh assert-completable "$NEXT"` refuses to mark the plan done
if `code` (or any other required review type) has no passing record —
review, then complete, in that order.

## Completion requires the work committed (plan 039)

Beyond the review gate, completion also requires the plan's **work product**
to be committed. On the completion path (`mstack-run` Step 7a) the orchestrator
MUST commit all declared changes (`MODIFIED + CREATED + DELETED`) and, after the
commit + hash-backfill amend, run `review-gate.sh assert-work-committed "$NEXT"`
before archiving and tagging. That check fails closed if any plan-attributable
path (a dirty/untracked path not in the persisted plan-start baseline) is left
uncommitted, or if the baseline file is missing. A working tree carrying
plan-attributable dirt at completion is an invalid terminal state and fails the
plan — a dirty "done" is not done. On failure the orchestrator halts and reports
the stray paths; it never auto-`git add`s them. The worker keeps its
never-commit contract — this commit-on-completion duty is the orchestrator's.
