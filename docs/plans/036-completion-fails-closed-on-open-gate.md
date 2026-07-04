---
id: 036
title: Completion/tagging fails closed on any open review gate
status: in-progress
blocked-by: [034, 035]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
---

## Requirements

With the gate mechanism (034) and the review records (035) in place, wire the
gate into every path that marks a plan done, cleared, or tagged, so an
implementing agent can never complete a plan while a review gate is open — and
so a `reviewed` status can never be silently downgraded.

**Acceptance criteria:**

- [ ] `mstack-run` Step 7a, before setting `status: done`, archiving, or tagging:
      run `review-gate.sh assert-completable "$NEXT"`. On nonzero, abort
      completion — leave the plan not-done, print a hard error naming the missing
      review(s) and how to run them, and do **not** create the
      `mstack/plan-${PLAN_ID}-done` tag. Fail closed.
- [ ] Any other path that could mark a plan **done** or write the done tag is
      guarded by the same assertion. The audit is a **repo-wide grep** for
      frontmatter status writes and tag creation, not a two-file scan. The
      confirmed done+tag site is Step 7a (`status: done` at `SKILL.md:625`, tag at
      `SKILL.md:681`). Scope precisely: the completion gate targets the
      **→ done** transition and the done tag. `mstack-backlog`'s
      `status: skipped/blocked` and plan-doctor Step 5's `needs-review` edits are
      *different* transitions (not completion), so they are **noted by the audit
      but not blocked by the completion gate** — call this out so an executor
      doesn't wrongly guard skipped/blocked. (If `mstack-backlog/SKILL.md` needs
      any edit, it is only to add that clarifying note; it is otherwise not a
      completion site.)
- [ ] Before writing frontmatter that touches review state, run
      `review-gate.sh assert-no-downgrade`; refuse the write if it would
      downgrade. Be precise about what it protects: the enforcement-relevant
      fields are `reviews:` verdicts and `review-required`. The `reviewed:` field
      is the *human*-review flag (set fresh to `false` at Step 7a, flipped to
      `true` by the human out-of-band) — it is orthogonal to the gate, so at
      Step 7a `assert-no-downgrade` is effectively inert (HEAD has no `reviewed`
      yet; `false` is an add, not a downgrade). Its `reviewed: true→false`
      protection matters only for later out-of-band edits — verify it with a
      dedicated fixture, don't pretend Step 7a exercises it.
- [ ] The done-site audit **exempts test/smoke fixtures**: `bin/mstack-codex-smoke`
      hand-writes `status: done` on fixture plan `001-create-hello`; the gate must
      not block smoke fixtures. Ensure the smoke fixture has `needs-review: none`
      / no `review-required` (nothing to record) so it completes cleanly, and
      exempt fixture paths from the guard.
- [ ] `mstack-status` and `mstack-plan-doctor` surface gate state for a plan
      ("blocked: eng review required but not recorded"), so an open gate is
      visible, not silent.
- [ ] `AGENTS.md` documents the end-to-end invariant: authoring declares required
      reviews -> only review skills record verdicts -> completion refuses until
      recorded -> reviewed status cannot be downgraded.

## Design

**Single choke point.** Step 7a is the one place that transitions a plan to done
and tags it; the assertion goes there, before the first irreversible step (the
status edit). Everything downstream (archive, tag, manifest cleanup) only runs
after `assert-completable` passes.

**What this plan is and isn't.** Wiring `assert-completable` into Step 7a only
stops the agent that *runs* Step 7a. An agent that skips Step 7a and hand-writes
`status: done` + `git tag` bypasses it entirely — the review's core finding. So
this plan is **anti-forgetfulness**: it makes the honest completion path refuse
when a gate is open. The **non-optional** barrier (a git hook that rejects the
bad commit/tag no matter how it was produced) and the retroactive audit live in
**plan 038**, which is what actually closes the "proceed outside the picker"
hole. Frame it that way here; do not claim Step 7a alone makes completion
unbypassable.

**Reconcile with the picker.** `pick-next.sh` already skips
`needs-review != none`, but that flag is forgeable. The picker is convenience;
Step 7a's gate is the honest-path enforcement; the 038 hook is the barrier.
Three layers, each named for what it actually stops.

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: Step 7a completion sequence + any other done/tag
  site; add the `assert-completable` and `assert-no-downgrade` calls with the
  fail-closed abort behavior.
- `skills/mstack-run/references/review-spec.md`: reflect that the code gate must
  be recorded and that completion asserts it.
- `skills/mstack-status/SKILL.md` + `status.sh`, `skills/mstack-plan-doctor/SKILL.md`:
  surface open-gate state.
- `AGENTS.md`: the end-to-end invariant.

**Out of scope:** changing `pick-next.sh` selection logic (it already skips
needs-review plans); redesigning the record format (owned by 034).

**Shared-file coordination.** `mstack-run/SKILL.md`, `AGENTS.md`,
`mstack-plan-doctor/SKILL.md`, `mstack-status/SKILL.md`, and `review-gate.sh` are
edited by several plans in this goal. Edit by **text anchor, not line number**
(the cited `:625/:681` refs drift once a sibling edits the file first), and
re-read each shared file immediately before editing.

## Tasks

1. Insert `assert-completable` at the top of `mstack-run` Step 7a; on failure,
   abort with a hard error and skip tag/archive.
2. Audit and guard every other `status: done` / done-tag site.
3. Insert `assert-no-downgrade` before any `reviewed`/`reviews` frontmatter
   write.
4. Surface gate state in `mstack-status` and `mstack-plan-doctor`.
5. Document the end-to-end invariant in `AGENTS.md`.

## Verification

- `[cmd]` `bash -n` / `shellcheck` on any scripts touched.
- `[cmd]` a completion-simulation harness on a fixture plan with an open gate
  exits nonzero and creates **no** `mstack/plan-*-done` tag.
- `[cmd]` the same harness on a fixture whose reviews are all recorded completes
  (status -> done, tag created).
- `[cmd]` a legacy fixture (`needs-review: eng`, no `review-required`, no
  recorded verdict) is **not** completable — Step 7a aborts (proves the
  fail-closed migration rule from 034, the single most important case).
- `[cmd]` an attempted `reviewed: true -> false` write on a fixture whose HEAD
  already has `reviewed: true` is refused by `assert-no-downgrade` (nonzero exit,
  frontmatter unchanged). Note the real non-optional bypass test (hand-written
  done outside Step 7a) lives in plan 038; Step 7a's checks are honest-path only.
- `[assert]` `mstack-status` for the open-gate fixture shows the gate as blocking
  (output contains the "review required but not recorded" state).
