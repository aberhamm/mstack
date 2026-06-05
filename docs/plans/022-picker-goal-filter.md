---
id: 022
title: Teach picker to filter candidates by goal name
status: done
blocked-by: [021]
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

With plan identity now `(goal, id)` from plan 021, the picker needs a way to
filter candidates by goal name. When `--goal <slug>` is passed, only plans
with a matching `goal:` frontmatter value are considered for execution.

**Acceptance criteria:**

- [ ] `pick-next.sh` accepts a `--goal <slug>` flag before the positional scope argument
- [ ] When `--goal` is provided, only plans whose `goal:` frontmatter matches the slug are candidates for selection
- [ ] The `--goal` filter composes with the numeric scope filter as AND (both must match when both provided)
- [ ] When `--goal` is provided alone (no numeric IDs), all plans with that goal are candidates
- [ ] When no plans match the goal filter, the picker exits with `EXIT_GOAL_NOT_FOUND` (15) and a diagnostic on stderr
- [ ] When `--goal ""` is passed (empty string), it is treated as no filter (backward compatible)
- [ ] Backward compatible: calling `pick-next.sh` without `--goal` works exactly as before
- [ ] Validation loops (duplicate detection, cycle detection) operate on the full plan set regardless of goal filter

## Design

**Argument parsing:** Parse `--goal <slug>` from `$@` before processing the
positional scope filter. Use a while-shift loop:

```bash
GOAL_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --goal) GOAL_FILTER="$2"; shift 2 ;;
    *) break ;;
  esac
done
SCOPE_FILTER="${1:-}"
```

After the loop, `$1` (if any) is the numeric scope CSV. `GOAL_FILTER` holds
the goal slug or empty string.

**`matches_goal()` function:** Takes a file path. Reads `goal:` via `fm_get`.
Returns 0 if `GOAL_FILTER` is empty OR if the plan's goal matches `GOAL_FILTER`.
Returns 1 otherwise.

```bash
matches_goal() {
  local f="$1"
  [ -z "$GOAL_FILTER" ] && return 0
  local plan_goal
  plan_goal="$(fm_get "$f" goal || true)"
  [ "$plan_goal" = "$GOAL_FILTER" ]
}
```

**Apply in candidate loop:** After `in_scope "$id"`, add `matches_goal "$f" || continue`.

**Exit code for no match:** After the candidate loop, if `GOAL_FILTER` is set
and no candidate was found, check whether any plan has the matching goal. If
none exist at all, exit `EXIT_GOAL_NOT_FOUND` (15) with diagnostic. If plans
exist but are all done/blocked, fall through to the existing exit 10/12 logic.

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next.sh`: add `--goal` argument parsing, add `matches_goal` function, apply in candidate loop, handle exit 15

**Out of scope:** mstack-run SKILL.md changes (plan 023). manifest.sh changes
(plan 023). plan-multi changes (plan 024).

Testing approach: unit-only

## Tasks

1. Add argument parsing loop at the top of `pick-next.sh` (before `SCOPE_FILTER` assignment): parse `--goal <slug>` into `GOAL_FILTER`, shift, then assign remaining `$1` to `SCOPE_FILTER`. Add comment: `# --goal consumed; $1 is now the numeric scope CSV if any`
2. Add `matches_goal()` function after the existing `in_scope()` function
3. Add `matches_goal "$f" || continue` in the candidate selection loop, after the `in_scope` check
4. After the candidate loop, when `GOAL_FILTER` is set and no best_path found: scan ALL_ID_MAP for any plan with matching goal. If none exist, `echo "goal '$GOAL_FILTER' not found in any plan file" >&2; exit $EXIT_GOAL_NOT_FOUND`. If some exist but all done/blocked, fall through to existing exit 10/12 logic.

## Verification

Checks:
- [cmd] grep -q "GOAL_FILTER" skills/mstack-run/scripts/pick-next.sh
- [cmd] grep -q "matches_goal" skills/mstack-run/scripts/pick-next.sh
- [cmd] grep -q "\-\-goal" skills/mstack-run/scripts/pick-next.sh
- [cmd] bash -n skills/mstack-run/scripts/pick-next.sh

## Implementation Notes

Added `--goal <slug>` filtering to pick-next.sh. While-shift argument parsing loop consumes `--goal` before the positional scope CSV. `matches_goal()` function compares plan `goal:` frontmatter against GOAL_FILTER with empty-filter bypass. Filter applied in the candidate selection loop after `in_scope`. Goal-not-found exits with code 15 when no plan declares the requested goal, with fall-through to existing exit 10/12 when plans exist but are all done/blocked. Validation loops (duplicate/cycle detection) remain unfiltered.

**Files changed:**

- `skills/mstack-run/scripts/pick-next.sh` (modified)

**Commit:** `52e2ec3` — `feat(mstack-run): goal-based candidate filtering in picker`
