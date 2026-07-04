---
id: 038
title: Non-optional enforcement — git hook + retroactive review audit
status: done
blocked-by: [034, 036]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
completed: 2026-07-04
reviewed: false
qa: automated
---

## Requirements

The completion gate in plan 036 only fires if the agent chooses to run
`review-gate.sh` inside Step 7a. Both eng-review passes flagged this as the core
hole: an agent that skips Step 7a and hand-writes `status: done` +
`git tag mstack/plan-NNN-done` (both plain instructions today at
`mstack-run/SKILL.md:625,681`) bypasses every check. There are no git hooks in
the repo today (`.git/hooks` empty, no `core.hooksPath`), so the invariant is
prose the same LLM can decline to run. The user's requirement — an agent "must
not be able to self-clear or route around it" — is not met by a script the agent
optionally calls.

This plan adds the layers that fire *regardless of the agent's cooperation*:

1. A **git hook** (installed via a tracked `core.hooksPath`) that rejects a bad
   commit at write time.
2. A **startup guard** so mstack refuses to operate when the hook is missing or
   stale (an agent that removes the hook is caught on the next run).
3. A **retroactive audit** that scans completed plans for missing verdicts —
   the backstop for `--no-verify` and out-of-band edits.

**Honest residual (state it plainly).** Git hooks are local-only (not cloned)
and bypassable with `git commit --no-verify`. So this plan makes the invariant
**deterrent + detectable**, not cryptographically unbypassable — that is
impossible when every actor is the same agent with shell access. The audit is
what converts "bypassable" into "bypass leaves an evidence trail the next
audit/status run surfaces." Do not claim more than that.

**Acceptance criteria:**

- [ ] A `pre-commit` hook rejects any staged plan whose frontmatter transitions
      to `status: done` while `review-gate.sh assert-completable` fails, or that
      weakens `review-required` / `reviews` / `reviewed` while
      `assert-no-downgrade` fails. Rejection prints the missing review(s) and the
      remedy.
- [ ] Tag creation of `mstack/plan-*-done` on a non-completable plan is rejected
      (a `pre-push` hook rejecting the tag ref, plus the Step 7a script guard
      from 036 for the local-tag moment, since git has no pre-tag hook).
- [ ] The hook ships in a **tracked** directory and is installed by
      `mstack-init` / `setup` via `git config core.hooksPath` (git's default
      `.git/hooks` is not cloned, so a tracked path is required for the hook to
      exist in any repo running mstack).
- [ ] `review-gate.sh assert-hook-installed` verifies the hook is present and
      current; `mstack-run` and `mstack-plan-doctor` call it at startup and
      refuse to proceed (with install instructions) if it is missing/stale.
- [ ] `review-gate.sh audit` (surfaced by `mstack-status` / `mstack-plan-doctor`)
      scans all `done`/archived plans and flags any whose `review-required` types
      lack a passing `reviews:` record — catching completions made with
      `--no-verify` or by out-of-band edits.
- [ ] Prose in `mstack-run`/036 that previously implied Step 7a alone is
      "unavoidable" is reconciled: picker = convenience, Step 7a gate =
      honest-path check, hook = write-time barrier, audit = retroactive backstop.

## Design

**Hook location + install.** Ship the hook script under a tracked dir (e.g.
`.githooks/pre-commit`, `.githooks/pre-push`, or shipped from the skill and
copied in). `mstack-init` sets `core.hooksPath` to it. This is the only way a
hook exists in a freshly cloned consumer repo. The hook sources `lib.sh` +
`review-gate.sh` by resolving the installed skill dir (the existing `skill_dir`
helper), so it works across Skillshare/Codex/Claude installs.

**pre-commit logic.** For each staged `docs/plans/**.md` (and `archive/`), diff
staged-vs-HEAD frontmatter; if `status` becomes `done` → `assert-completable`;
if review fields weaken → `assert-no-downgrade`. Any failure → nonzero exit,
commit rejected. Non-plan commits pass untouched (cheap early-exit).

**Why the audit is the real backstop.** `--no-verify` skips the hook and local
hooks can be deleted; `assert-hook-installed` catches a deleted hook on the next
mstack run, and `audit` catches a `--no-verify` completion whenever status/doctor
runs. Layered detection, not a wall.

**Files expected to change:**

- New tracked hook scripts (e.g. `.githooks/pre-commit`, `.githooks/pre-push`).
- `skills/mstack-run/scripts/review-gate.sh`: `assert-hook-installed`, `audit`.
- `skills/mstack-init/SKILL.md` + `setup`: install `core.hooksPath`; idempotent.
- `skills/mstack-run/SKILL.md`, `skills/mstack-plan-doctor/SKILL.md`: startup
  `assert-hook-installed`; surface `audit` output.
- `skills/mstack-status/SKILL.md`: show audit findings.
- `AGENTS.md`: the layered-enforcement model + honest residual.

**Out of scope:** the record format + gate primitives (034), completion wiring
(036), approval-commit (037). This plan makes those non-optional; it does not
redefine them. Not attempting to defend against an actor who both `--no-verify`s
and suppresses the audit — documented as out of achievable scope.

**Shared-file coordination.** `mstack-run/SKILL.md`, `mstack-plan-doctor/SKILL.md`,
`mstack-status/SKILL.md`, `AGENTS.md`, `review-gate.sh`, and `mstack-init`/`setup`
are edited by several plans in this goal. Edit by **text anchor, not line
number** (the cited `:625/:681` refs drift once a sibling edits first), and
re-read each shared file immediately before editing.

## Tasks

1. Write the tracked `pre-commit` / `pre-push` hook scripts calling
   `review-gate.sh`.
2. Add `assert-hook-installed` + `audit` to `review-gate.sh`.
3. Install `core.hooksPath` from `mstack-init` / `setup` (idempotent).
4. Wire startup `assert-hook-installed` into `mstack-run` + `mstack-plan-doctor`.
5. Surface `audit` in `mstack-status` / `mstack-plan-doctor`.
6. Document the layered model + residual in `AGENTS.md`; reconcile 036 prose.

## Verification

- `[cmd]` `bash -n` + `shellcheck` on the hook scripts and `review-gate.sh`.
- `[cmd]` **the real bypass test:** with the hook installed, a commit that flips a
  fixture plan `pending→done` without recorded verdicts is **rejected**
  (nonzero, commit not created). This is the check 036 could not make.
- `[cmd]` a commit that flips `pending→done` with all required verdicts recorded
  is accepted.
- `[cmd]` `assert-hook-installed` exits nonzero when `core.hooksPath` is unset;
  after `mstack-init`, exits 0.
- `[cmd]` `review-gate.sh audit` flags a fixture done-plan whose `review-required`
  type has no passing record, and is silent for a fully-recorded done-plan.

## Implementation Notes

Added the non-optional git-hook enforcement barrier. Tracked hooks
(`.githooks/pre-commit`, `.githooks/pre-push`) are thin shims that locate the
installed mstack-run skill and delegate to `review-gate.sh hook-pre-commit` /
`hook-pre-push` (heavy logic lives in one linted place; source shipped under
`skills/mstack-run/hooks/`). The pre-commit gate checks STAGED content
(`git show :path` vs `git show HEAD:path`): a `pending→done` transition runs
`assert-completable`, a weakening of `review-required`/`reviews`/`reviewed`
runs `assert-no-downgrade`; failures reject the commit. New exit codes: 26
(`assert-hook-installed`), 27 (`audit`) in lib.sh, non-colliding with 21–25.
Hooks install to `.githooks/` via `git config core.hooksPath .githooks`
(idempotent, wired into `mstack-init`/`setup`). Startup `assert-hook-installed`
guards `mstack-run` Step 1 and `mstack-plan-doctor`; `audit` scans done/archived
plans for missing verdicts (the `--no-verify`/out-of-band backstop) and is
surfaced by `mstack-status`/`mstack-plan-doctor`. AGENTS.md documents the
four-layer model (picker = convenience → Step 7a = honest-path → hook =
write-time barrier → audit = retroactive backstop) and the honest residual:
hooks are local-only and `--no-verify`-bypassable, so this is deterrent +
detectable, not cryptographically unbypassable.

Independently verified in isolated temp repos: the real bypass test rejects a
`pending→done` commit with no recorded verdict (the check 036 could not make),
while claim (`pending→in-progress`), empty-required-set completions
(`needs-review: none`), and `git mv` archive moves are all ACCEPTED — the hook
does not brick the normal loop. `core.hooksPath` was left UNSET in the working
repo by the implementation; the parent activates it after landing this plan.

**Files changed:**

- `AGENTS.md` (modified)
- `setup` (modified)
- `skills/mstack-init/SKILL.md` (modified)
- `skills/mstack-plan-doctor/SKILL.md` (modified)
- `skills/mstack-run/SKILL.md` (modified)
- `skills/mstack-run/scripts/init.sh` (modified)
- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/review-gate.sh` (modified)
- `skills/mstack-run/scripts/status.sh` (modified)
- `skills/mstack-status/SKILL.md` (modified)
- `.githooks/pre-commit`, `.githooks/pre-push` (created)
- `skills/mstack-run/hooks/pre-commit`, `skills/mstack-run/hooks/pre-push` (created)

**Commit:** `8780c98` — `feat(mstack): non-optional enforcement — git hook + retroactive audit`
