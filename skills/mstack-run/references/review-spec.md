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
