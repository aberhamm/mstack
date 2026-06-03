---
id: 8
title: Add progress output and final validation pass to mstack-run goal execution
status: pending
blocked-by: []
needs-review: none
created: 2026-06-02
---

## Requirements

When running `/goal all pending mstack plans are done or failed`, the user has no
visibility into what the agent is doing or how far along it is. The only feedback
is the final changelog after everything completes. For backlogs with 5-10 plans
that take 30-60 minutes, this is a poor experience.

This plan adds structured progress output to mstack-run so the user can glance at
the terminal and know: which plan is running, how many remain, and what stage the
current plan is in.

**Acceptance criteria:**

- [ ] At the start of a goal run, output a backlog summary: total plans, how many pending, how many blocked, how many done/failed
- [ ] Before each plan starts, output: `[mstack] Plan N/M: <title> (plan <id>)`
- [ ] At each major milestone within a plan, output a progress line:
  - `[mstack] ├─ Implementing...`
  - `[mstack] ├─ Health gate: <score>/10 (<verdict>)`
  - `[mstack] ├─ Code review: <N> findings, <N> fixed`
  - `[mstack] └─ Committed: <commit message first line>`
- [ ] On plan failure, output: `[mstack] └─ FAILED: <one-line reason>`
- [ ] On plan skip (blocked dependencies failed), output: `[mstack] └─ SKIPPED: blocked by failed plan <id>`
- [ ] After all plans complete but before the summary, run a final full-suite validation pass: execute the project's complete test suite (typecheck, lint, all tests, E2E) across the entire codebase, not scoped to any single plan
- [ ] The final validation catches cross-plan regressions: cases where plan 3's changes break something plan 1 introduced that the per-plan health gate missed because each plan passed in isolation
- [ ] Output the final validation as: `[mstack] Final validation: running full test suite...` followed by `[mstack] Final validation: <score>/10 (PASS)` or `[mstack] Final validation: FAILED (<which categories failed>)`
- [ ] If the final validation fails, output which specific tests/checks failed and which plan likely introduced the regression (by checking git blame on the failing lines against plan commit hashes)
- [ ] Final validation failure does not mark any plan as failed (they all passed individually); instead it outputs a warning: `[mstack] WARNING: Cross-plan regression detected. Review the failures above before pushing.`
- [ ] At the end of the goal run, output a summary: `[mstack] Done. <N> completed, <N> failed, <N> skipped. Run /mstack-changelog to review.`
- [ ] Progress output uses the `[mstack]` prefix consistently so it's visually distinct from the agent's working output
- [ ] Tree-drawing characters (├─, └─) indicate whether more milestones follow or this is the last one for the current plan
- [ ] All progress output is plain text printed to the user, not written to files

## Design

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: add progress output instructions at each pipeline stage

**Approach:**

mstack-run is a skill (prompt-driven, not code). Progress output means adding
explicit instructions to print status lines at specific points in the execution
flow. The skill already has defined stages (implement, health gate, review, commit,
checkpoint). At each stage boundary, the agent outputs a progress line.

The backlog summary at the start requires reading all plan files and counting by
status, which mstack-run already does for pick-next logic. The plan count (N/M)
requires tracking how many plans have been processed in the current goal run.

Implementation approach: add a "Progress output" section to mstack-run's SKILL.md
that defines the format and specifies exactly when each line should be printed.
Add inline instructions at each pipeline stage ("Before running health gate,
print: ...").

The `[mstack]` prefix and tree characters are chosen to be visually scannable
in a terminal without requiring any special rendering.

**Final validation pass (after loop exits, before summary):**

After all plans have been executed (or failed/skipped), run one final health
gate pass across the entire codebase. This is the same health-check.sh but
without a PLAN_ID, so it checks everything, not just one plan's changes.

```
[mstack] Final validation: running full test suite...
[mstack] Final validation: 9.2/10 (PASS)
[mstack] Done. 5 completed, 0 failed, 0 skipped. Run /mstack-changelog to review.
```

On failure:
```
[mstack] Final validation: FAILED (test: 6/10, lint: 4/10)
[mstack] WARNING: Cross-plan regression detected.
[mstack]   test failures: 3 tests in src/billing/__tests__/usage.test.ts
[mstack]   likely source: plan 003 (commit abc1234) modified usage-service.ts
[mstack]   Review the failures above before pushing.
[mstack] Done. 5 completed, 0 failed, 0 skipped (but final validation failed).
```

The regression attribution uses `git blame` on failing test lines to identify
which plan commit likely introduced the issue. This is best-effort; if blame
can't isolate it, just report the failures without attribution.

**Out of scope:**

- Writing progress to a file or structured log
- Real-time progress within a single stage (e.g., "implementing line 45 of 200")
- Progress bars or percentage complete
- Changes to mstack-status (it reads from artifacts, not live output)
- Changes to mstack-checkpoint (it tracks crash recovery state, not live progress)
- Auto-fixing final validation failures (the user reviews and decides)

## Tasks

1. Add a "Progress output" section to mstack-run SKILL.md defining the format, prefix, and tree characters
2. Add backlog summary output instruction at the start of the pick-next loop (before first plan)
3. Add plan header output instruction when a plan is selected ("Plan N/M: ...")
4. Add milestone output instructions at each stage boundary: post-implement, post-health, post-review, post-commit
5. Add failure and skip output instructions
6. Add final validation pass after loop exits: run full health gate without PLAN_ID, output results, attribute regressions via git blame
7. Add goal-complete summary output instruction after final validation

## Verification

- [assert] grep -q '\[mstack\]' skills/mstack-run/SKILL.md
- [assert] grep -q 'Plan.*N/M\|Plan.*of.*total' skills/mstack-run/SKILL.md
- [assert] grep -q 'Health gate' skills/mstack-run/SKILL.md
- [assert] grep -q 'FAILED\|failed' skills/mstack-run/SKILL.md
- [assert] grep -q 'Done\.\|summary' skills/mstack-run/SKILL.md
- [assert] grep -qi 'final validation\|full.*test.*suite\|cross-plan.*regression' skills/mstack-run/SKILL.md
- [assert] grep -qi 'git blame\|regression.*attribution\|likely.*source' skills/mstack-run/SKILL.md
