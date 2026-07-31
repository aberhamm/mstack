---
id: 087
title: detect plans whose work shipped but whose status never closed
status: pending
blocked-by: []
priority: 36
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-31
qa: automated
---

## Requirements

A plan can be fully implemented — code shipped, committed, verification passing
— and still sit at `status: pending` forever, because the completion bookkeeping
(Step 7a: the `status: done` write, the archive, the tag) never ran. Nothing in
mstack detects this. The picker selects on `status: pending` alone, so the next
unscoped run hands a worker a plan with nothing left to do, and that worker
either re-implements shipped work or thrashes trying to find something to change.

**This is an observed failure, not a hypothetical.** Plans 045, 046, and 047 in
this repository are all in exactly this state right now: every acceptance
criterion verified passing, shipped code present (`review-gate.sh plan-authored`,
`verify-lint.sh probe`, `health-reach.sh` + its smoke suite), commits landed
(`ba4e5b3`, `2c889da`, `56020fe`) — and all three still read `status: pending`.
They are the picker's first three picks. It happened three times in one backlog
and no plan in the backlog covers it.

Plan 075 (stranded state self-healing) covers three adjacent stranding modes:
a plan blocked by a dependency that later succeeded, a plan left `in-progress`
by a crash, and a stale hook aborting a run. It does NOT cover "the work is
done and the plan file doesn't know." That is a distinct mode with a distinct
detector.

**Acceptance criteria:**

- [ ] A deterministic check reports, for each `pending` plan, whether that
      plan's own `## Verification` executable checks ALL already pass against
      the current tree — i.e. the plan appears already satisfied.
- [ ] The check is READ-ONLY. It never edits frontmatter, never marks anything
      done, never archives, never tags. Closing a plan stays Step 7a's job via
      the honest path; this only reports.
- [ ] It reuses the existing probe machinery from plan 046
      (`verify-lint.sh probe`) rather than inventing a second executor.
- [ ] `[manual]` checks are ignored (they prove nothing automatically) and a
      plan whose verification is ENTIRELY `[manual]` is reported as
      `UNDETERMINED`, never as satisfied.
- [ ] Any check that errors, times out, or cannot be probed makes the plan
      `UNDETERMINED`, never `SATISFIED`. Fail-closed: a false "already done"
      would strand real work, which is the more expensive error.
- [ ] `mstack-status` surfaces satisfied-but-pending plans as a distinct
      warning line, citing each as `NNN: Title` per the plan citation
      convention.
- [ ] `mstack-run` runs the check at startup for the plan it is about to pick
      and refuses to execute a `SATISFIED` plan, reporting it instead of
      burning an iteration on it.
- [ ] A smoke suite covers: satisfied plan detected, genuinely-pending plan not
      flagged, all-`[manual]` plan reported UNDETERMINED, erroring check
      reported UNDETERMINED.

## Design

The detector is a new subcommand rather than a new script where possible —
`verify-lint.sh` already parses a plan's Verification block and already knows
how to classify check types, so extending it keeps one parser. A plan is
`SATISFIED` only when it has at least one executable check and every executable
check exits 0.

The `mstack-run` integration is deliberately a REFUSAL, not an auto-close. An
agent that auto-marked plans done from a heuristic would be exactly the
gate-bypassing behavior AGENTS.md forbids: only the honest Step 7a path, with
its review-gate assertions, may write `status: done`. The correct response to
a satisfied-but-pending plan is to tell the human, who runs the completion path.

Note the interaction with review gates: a plan can be satisfied AND still have
an open review gate (046 is exactly this — code shipped, `assert-completable`
returns 23 because no eng verdict was ever recorded). The report must
distinguish "satisfied, gate clear, ready to close" from "satisfied, gate open,
needs a review recorded first" so the human knows which action to take.

**Files expected to change:**

- `skills/mstack-run/scripts/verify-lint.sh`: add the satisfied-check subcommand
- `skills/mstack-run/scripts/lib.sh`: exit code for the new state, if one is
  needed; do not collide with 10-19, 20, 21-22, 23-28, 30-34
- `skills/mstack-status/SKILL.md`: surface the warning
- `skills/mstack-run/SKILL.md`: startup refusal for a satisfied plan
- `skills/mstack-run/scripts/verify-lint-smoke.sh`: extend with the new cases
- `AGENTS.md`: document the state and the fact that it never auto-closes

**Out of scope:** auto-closing anything; changing Step 7a; retroactively
closing 045/046/047 (do that through the honest path, separately); detecting
partially-satisfied plans, which is a judgment call this check must not make.

## Tasks

1. Read `verify-lint.sh cmd_probe` and determine whether the satisfied-check
   is a new subcommand there or a thin wrapper around it.
2. Implement the check with fail-closed UNDETERMINED semantics.
3. Add the gate-state distinction (satisfied+clear vs satisfied+gate-open) by
   calling `review-gate.sh assert-completable`.
4. Wire the `mstack-status` warning line, using `plan_label` for citations.
5. Wire the `mstack-run` startup refusal.
6. Extend `verify-lint-smoke.sh` with the four cases.
7. Document in AGENTS.md, including the explicit never-auto-closes rule.

## Verification

Checks:
- `[cmd] bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- `[assert] bash skills/mstack-run/scripts/verify-lint.sh --help 2>&1` contains `satisfied`
- `[cmd] bash skills/mstack-run/scripts/status.sh`
- `[cmd] bash -n skills/mstack-run/scripts/verify-lint.sh skills/mstack-run/scripts/lib.sh`
- `[cmd] shellcheck skills/mstack-run/scripts/verify-lint.sh`
- `[assert] grep -c 'never auto-close\|never auto-closes' AGENTS.md` contains `1`
- `[manual] run the check against plans 045 and 047 and confirm both report SATISFIED with a clear gate, and 046 reports SATISFIED with an open eng gate`
