---
id: 075
title: self-heal stranded plan states at run startup
status: pending
blocked-by: [061, 074]
priority: 34
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Three states today require a human even though the remediation is fully
deterministic. (a) A plan skipped over a failed dependency gets
`status: blocked` + `blocked-reason: dependency failed (plan <id>: <title>)`
(`skills/mstack-run/SKILL.md:756-757`) and stays blocked forever even after
that dependency later completes — `pick-next.sh` selects only
`status: pending` (selection rules, pick-next.sh:5-10). (b) A crash mid-plan
leaves `status: in-progress`; mstack-run's crash-recovery step reads the
checkpoint and merely reports "Plan remains in-progress; pick-next will skip
to the next plan" (SKILL.md:170-175) — the actual reset lives only in
plan-doctor ("reset them automatically to `status: pending`",
`skills/mstack-plan-doctor/SKILL.md:1124-1125`). (c) On
`assert-hook-installed` failure (exit 26) both mstack-run (SKILL.md:117-140)
and plan-doctor (plan-doctor SKILL.md:61-68) BAIL with "install it with
mstack-init" — even though mstack-run's auto-init block just above already
runs `init.sh bootstrap` when `.mstack/` is missing (SKILL.md:75), and
init.sh's step 6 (init.sh:85-125) is precisely the hook installer.

**Acceptance criteria**

- [ ] AUTO-UNBLOCK: at run startup, a blocked plan whose `blocked-reason:`
      matches the dependency-failed pattern flips to `status: pending` IFF
      the named dependency is now `status: done`. Human defers are exempt:
      backlog's defer writes `deferred: <date>` + `deferred-reason:`
      (`skills/mstack-backlog/SKILL.md:150-158`); presence of either field
      disables auto-unblock for that plan.
- [ ] IN-PROGRESS RESET: mstack-run Step 1 itself resets a
      checkpoint-diagnosed crashed `in-progress` plan to `status: pending`,
      instead of only reporting it.
- [ ] HOOK SELF-REINSTALL: on exit 26, run init.sh's hook-install step,
      re-assert ONCE, and bail only if still failing; log the old-vs-new
      hook diff so tamper-vs-drift is legible.
- [ ] All healing writes are frontmatter-only, committed by explicit file
      list, and logged one line per healed plan (cited as `NNN: Title`).
- [ ] No healing pass ever touches `status: done/failed/skipped` plans,
      review state, or `review-required`.

## Design

One new deterministic script, `skills/mstack-run/scripts/heal.sh`, invoked
from mstack-run Step 1 after crash-recovery and before pick-next — not inside
pick-next.sh, whose contract is a pure read-only selector; putting writes in
the picker would also run them on every scoped invocation. `heal.sh` handles
(a) and (b); it parses the dependency id out of `blocked-reason:` with the
same lenient single-line frontmatter idiom pick-next uses, checks the target
plan's `status: done` (including `docs/plans/archive/`), and skips any plan
carrying `deferred:` or `deferred-reason:`. Environment blocks from plan 074
(`blocked-reason:` naming a missing tool, not a dependency) do not match the
dependency pattern and are left alone by construction. For (b) it takes the
crashed plan id as an argument from the checkpoint read (SKILL.md:161-175) —
it heals only the already-diagnosed plan, it does not re-diagnose.

For (c), the mstack-run and plan-doctor bail blocks change from "print remedy
and exit" to: save a copy of the current `.githooks/pre-commit`/`pre-push`
(if present), run `bash "$SKILL_DIR/scripts/init.sh" bootstrap` (idempotent —
init.sh refreshes hooks from shipped source every run), diff old vs new to
stderr, re-run `assert-hook-installed` exactly once, and bail with the
existing message only on a second failure. One attempt, no loop. This lands
after plan 061's changes to `assert-hook-installed` messaging, hence the
dependency; align the printed text with whatever 061 ships.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/heal.sh`: new (auto-unblock + in-progress reset).
- `skills/mstack-run/scripts/heal-smoke.sh`: new smoke suite.
- `skills/mstack-run/SKILL.md`: Step 1 wiring; hook-bail block becomes
  self-reinstall-then-re-assert.
- `skills/mstack-plan-doctor/SKILL.md`: same self-reinstall change to its
  hook-guard block.
- `AGENTS.md`: update the startup-invariant sentence to the self-reinstall
  semantics.

**Out of scope:** changing pick-next.sh selection semantics; healing
`failed` plans (that is plan 074's retry path); auto-unblocking deferred or
environment-blocked plans; any push or non-frontmatter edit.

## Tasks

1. Write `heal.sh` (fixture-driven, repo-root aware) with the
   dependency-pattern match, done-check, and defer exemption.
2. Write `heal-smoke.sh` covering: dep-now-done → pending; dep still
   failed → untouched; `deferred-reason` present → untouched; crashed
   in-progress id → pending; done/skipped plans never touched.
3. `chmod +x` + `git update-index --chmod=+x` both new scripts.
4. Wire `heal.sh` into mstack-run Step 1 and update the two hook-bail
   blocks to install→diff→re-assert-once→bail.
5. Update the AGENTS.md startup-invariant sentence ("mstack-run and
   mstack-plan-doctor run assert-hook-installed at startup and refuse to
   operate if the hook was removed or edited") to the new semantics —
   attempt one self-reinstall from the shipped source, log the old-vs-new
   diff, and refuse only if reinstall fails or the source is unreachable.
6. Run the full smoke set.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/heal.sh skills/mstack-run/scripts/heal-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/heal.sh`
- [cmd] `bash skills/mstack-run/scripts/heal-smoke.sh`
- [assert] `grep -c "deferred" skills/mstack-run/scripts/heal.sh`
- [cmd] `grep -q "heal.sh" skills/mstack-run/SKILL.md`
- [cmd] `grep -q "re-assert" skills/mstack-plan-doctor/SKILL.md || grep -qi "re-run.*assert-hook-installed" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
