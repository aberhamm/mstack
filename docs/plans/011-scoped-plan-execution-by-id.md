---
id: 11
title: Scope plan execution by ID instead of "all pending"
status: pending
blocked-by: [10]
needs-review: none
created: 2026-06-03
---

## Requirements

When plan-multi creates plans, it currently suggests running `/goal all pending
mstack plans are done or failed`. This is dangerous when multiple agents or
sessions are creating plans concurrently: one session's goal run picks up plans
from a different session. It also means a user can't create plans for two
different features and choose to execute only one set.

This plan changes two behaviors:
1. Plan-multi (and any skill that creates plans) outputs the specific plan IDs
   it created and suggests a goal command scoped to those IDs.
2. mstack-run accepts a list of plan IDs to execute instead of always picking
   the next unblocked plan from the entire backlog.

**Acceptance criteria:**

Plan-multi output:

- [ ] After creating plans, plan-multi outputs a summary listing each plan ID and title: `Created plans: 008, 009, 010, 011`
- [ ] Plan-multi suggests a scoped goal command using the created IDs: `/goal complete mstack plans 008, 009, 010, 011` instead of `/goal all pending mstack plans are done or failed`
- [ ] Plan-multi never suggests "all pending" in its output; always uses specific IDs

Plan-new output:

- [ ] mstack-plan-new outputs the created plan ID after scaffolding: `Created plan 012: "<title>"`
- [ ] mstack-plan-new suggests the scoped run command: `Run with: /goal complete mstack plan 012` or `/mstack-run 012`

mstack-run scoped execution:

- [ ] mstack-run accepts an optional list of plan IDs as input (e.g., `$ARGUMENTS` = `008 009 010 011` or `008,009,010,011` or `plans 008-011`)
- [ ] When plan IDs are provided, mstack-run only picks from those plans (respecting dependency order within the set), ignoring all other pending plans in the backlog
- [ ] When no plan IDs are provided, mstack-run falls back to current behavior: pick the next unblocked plan from the entire backlog (backward compatible)
- [ ] Scoped execution still respects blocked-by dependencies: if plan 009 depends on plan 008, plan 008 runs first even if 009 was listed first
- [ ] If a scoped plan depends on a plan outside the scope (e.g., plan 009 depends on plan 005 which wasn't included), mstack-run reports an error: `[mstack] Plan 009 is blocked by plan 005, which is not in the execution scope and is not done. Either add 005 to the scope or complete it first.`
- [ ] The pick-next script (or equivalent logic) filters the candidate list by the provided IDs before applying dependency ordering
- [ ] Progress output (plan 008) uses the scoped count: `[mstack] Plan 2/4: ...` where 4 is the number of scoped plans, not the total backlog
- [ ] Final validation (plan 008) runs only the tests relevant to the scoped plans, not the entire backlog's changes (though the full health gate still runs since tests are codebase-scoped)

## Design

**Files expected to change:**

- `skills/mstack-plan-multi/SKILL.md`: change output to list created plan IDs and suggest scoped goal command
- `skills/mstack-plan-new/SKILL.md`: change output to show created plan ID and suggest scoped run
- `skills/mstack-run/SKILL.md`: add plan ID filtering to pick-next logic, handle out-of-scope dependency errors
- `skills/mstack-run/scripts/pick-next.sh`: add optional ID filter parameter

**Approach:**

**Plan-multi changes (output section):**

After plan files are written, collect the IDs:

```
Created plans:
  008  Add billing schema
  009  Stripe webhook integration
  010  Usage metering service
  011  Billing dashboard

Run: /goal complete mstack plans 008, 009, 010, 011
Or validate first: /mstack-plan-doctor
```

Never output "all pending mstack plans are done or failed" as a suggestion.

**Plan-new changes (output section):**

After the plan file is scaffolded:

```
Created plan 012: "Add rate limiting to API endpoints"
Run: /mstack-run 012
Or add to a batch: /goal complete mstack plans 012, ...
```

**mstack-run changes (pick-next logic):**

The `$ARGUMENTS` input is parsed for plan IDs. If present, the pick-next
logic filters to only those IDs.

```
If ARGUMENTS contains plan IDs (numeric, comma/space separated):
  SCOPE_IDS = parse IDs from ARGUMENTS
  For pick-next: only consider plans whose id is in SCOPE_IDS
  For each candidate:
    If blocked-by contains an ID not in SCOPE_IDS and that plan is not done:
      Error: "Plan X is blocked by plan Y, which is not in scope and not done"
  Track progress as N/len(SCOPE_IDS) not N/total_backlog

If ARGUMENTS is empty or non-numeric:
  Fall back to current behavior (all pending plans)
```

**pick-next.sh changes:**

Add an optional positional argument for ID filtering:

```bash
# Usage: pick-next.sh [id1,id2,id3]
SCOPE_FILTER="${1:-}"
```

If SCOPE_FILTER is non-empty, filter the candidate plans array to only those
matching the listed IDs before applying dependency sorting.

**Out of scope:**

- Changing the `/goal` prompt syntax (that's the user's natural language; mstack-run just parses IDs from whatever the user wrote)
- Plan grouping or tagging (IDs are sufficient for scoping)
- Concurrent execution of multiple scoped sets (one goal run at a time)
- Changing how plan-doctor operates (it always audits all plans or a specific one)

## Tasks

1. Update plan-multi SKILL.md output section: collect created plan IDs, output summary table, suggest scoped goal command instead of "all pending"
2. Update plan-new SKILL.md output: show created ID, suggest scoped run command
3. Add ID parsing to mstack-run SKILL.md: parse $ARGUMENTS for numeric IDs, set SCOPE_IDS
4. Add scope filtering to pick-next logic: filter candidates by SCOPE_IDS, validate out-of-scope dependencies
5. Update pick-next.sh to accept an optional ID filter parameter
6. Ensure progress output (plan 008) uses scoped count (N/scoped_total) when IDs are provided

## Verification

- [assert] grep -i 'Created plans\|created plan.*ID\|plan.*IDs' skills/mstack-plan-multi/SKILL.md
- [assert] grep -iv 'all pending' skills/mstack-plan-multi/SKILL.md | grep -qi 'goal.*complete\|goal.*plans'
- [assert] grep -i 'Created plan\|plan.*ID' skills/mstack-plan-new/SKILL.md
- [assert] grep -i 'SCOPE_IDS\|scope.*filter\|plan.*IDs\|id.*filter' skills/mstack-run/SKILL.md
- [assert] grep -i 'not in.*scope\|outside.*scope\|scope.*error' skills/mstack-run/SKILL.md
- [assert] grep -i 'SCOPE_FILTER\|scope\|filter' skills/mstack-run/scripts/pick-next.sh
