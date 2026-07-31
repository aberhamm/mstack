---
id: 086
title: characterize the Step 7a completion sequence with a smoke suite
status: skipped
blocked-by: []
priority: 28
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-31
qa: automated
skipped: 2026-07-31
skipped-reason: "duplicate: assert-completable ordering and assert-no-downgrade are already covered by review-gate-smoke.sh; its forcing function was 084, now dropped"
---

## Requirements

The Step 7a completion sequence — the ~290 lines of `skills/mstack-run/SKILL.md`
that mark a plan done, backfill the commit hash, assert the gates, archive the
file, and write the `mstack/plan-NNN-done` tag — is the single path every plan
in this repository flows through, and it has **no test of any kind**. It is
executed by an LLM following ordered prose. Plan 069 documented that this same
file's own linear-order summary skips a step and states the wrong status
transition, so "the agent will perform ten ordered git operations correctly
every time" is a demonstrated risk, not a hypothetical one.

This plan was split out of plan 084 (extract Step 7a to `complete.sh`). 084
proposed rewriting the sequence into a script; that refactor is deferred, but
its characterization test has standalone value TODAY and must exist before any
rewrite so the rewrite has something to prove itself against.

**Acceptance criteria:**

- [ ] `skills/mstack-run/scripts/complete-smoke.sh` exists, is committed mode
      `100755`, is self-contained, and runs in seconds against throwaway git
      repos it creates and destroys itself.
- [ ] The suite pins CURRENT behavior, not intended behavior. Where current
      behavior is wrong, the case documents it with a comment naming the plan
      that will change it — it does not encode the fix.
- [ ] Covers the ordered gate sequence: `assert-completable` runs before the
      `status: done` write, before the archive `git mv`, and before the tag;
      a nonzero exit from it aborts the whole sequence and leaves `status:
      blocked` with `needs-review` set to the still-open type(s).
- [ ] Covers `assert-work-committed` running AFTER the hash-backfill
      `git commit --amend` and BEFORE the archive `git mv`.
- [ ] Covers `assert-no-downgrade` refusing a `reviewed: true -> false` edit.
- [ ] Covers the tag-stranding case the SKILL.md war story describes twice: an
      archive `git mv` that lands without its tag, and vice versa.
- [ ] Registered in the `pre-commit` hook suite loop at its SHIPPED SOURCE
      (`skills/mstack-run/hooks/pre-commit`), then copied to
      `.githooks/pre-commit`, and listed in the AGENTS.md smoke-suite block.
- [ ] Adding the suite changes NO existing behavior; all seven existing suites
      still pass.

## Design

The suite follows the established pattern in `review-gate-smoke.sh` (266 lines)
and `health-reach-smoke.sh`: build a temp git repo with fixture plans, drive the
scripts directly, assert on exit codes and resulting file/tag state, clean up in
a trap.

The subject under test is prose, not a script, so the suite cannot invoke "Step
7a" as a unit. It tests the DETERMINISTIC PIECES the prose orchestrates —
`review-gate.sh assert-completable`, `assert-work-committed`,
`assert-no-downgrade`, and the git state each is supposed to observe — plus the
ORDER CONSTRAINTS between them, expressed as: given a repo in state X, the
assertion that Step 7a runs at that point must return Y. That is exactly the
contract `complete.sh` would later have to satisfy, which is what makes this a
usable characterization test for 084.

**Files expected to change:**

- `skills/mstack-run/scripts/complete-smoke.sh`: new, the suite
- `skills/mstack-run/hooks/pre-commit`: register the suite (shipped source)
- `.githooks/pre-commit`: refreshed copy of the above
- `AGENTS.md`: add the suite to the smoke-suite command block

**Out of scope:** creating `complete.sh`, changing any Step 7a prose, changing
any assertion's behavior, and fixing any wrong behavior the suite documents.
This plan only pins what is there now.

## Tasks

1. Read the Step 7a sequence in `skills/mstack-run/SKILL.md` and write down the
   ordered list of operations and the assertion that guards each one.
2. Write `complete-smoke.sh` following the `review-gate-smoke.sh` structure.
3. Add the gate-order cases, the work-committed-after-amend case, the
   no-downgrade case, and the tag/archive stranding cases.
4. `chmod +x` and `git update-index --chmod=+x` the new script.
5. Register in `skills/mstack-run/hooks/pre-commit`, copy to
   `.githooks/pre-commit` (do NOT run `./setup` from this checkout — it drops
   stray symlinks into the parent directory).
6. Add the suite to the AGENTS.md smoke-suite block.

## Verification

Checks:
- `[cmd] bash skills/mstack-run/scripts/complete-smoke.sh`
- `[cmd] test -x skills/mstack-run/scripts/complete-smoke.sh`
- `[assert] git ls-files -s skills/mstack-run/scripts/complete-smoke.sh | grep -q '^100755' && echo MODE_OK` contains `MODE_OK`
- `[assert] grep -c complete-smoke skills/mstack-run/hooks/pre-commit .githooks/pre-commit` contains `1`
- `[cmd] bash skills/mstack-run/scripts/script-mode-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/review-gate-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/health-reach-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/wrapup-scan-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/plan-ref-smoke.sh`
- `[cmd] bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- `[manual] confirm each case comments whether it pins correct or known-wrong behavior`
