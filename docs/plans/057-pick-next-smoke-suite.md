---
id: 057
title: Add pick-next-smoke suite covering the picker contract
status: pending
blocked-by: []
priority: 20
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

`skills/mstack-run/scripts/pick-next.sh` (~469 lines, the backlog selector
every run flows through) has ZERO smoke coverage and produced three Tier-1
audit findings (plans 054/055/056). Every other enforcement-critical script
has a suite; the picker's exit-code contract, dependency parsing, and
ordering rules are enforced by nothing. A new self-contained
`pick-next-smoke.sh` in the style of `review-gate-smoke.sh` (temp-repo
fixtures, deterministic, seconds to run) closes that.

Exit-code contract to pin — each verified against `lib.sh` lines 8-14 (the
audit brief misstated two of these; the constants are authoritative):
`0` `EXIT_PLAN_FOUND` (plan picked, path on stdout), `10` `EXIT_ALL_DONE`,
`11` `EXIT_SCOPED_NOT_FOUND`, `12` `EXIT_ALL_BLOCKED` (including the new
unscoped case from plan 054), `13` `EXIT_CYCLE`, `14` `EXIT_DUPLICATE_IDS`,
`15` `EXIT_GOAL_NOT_FOUND`.

**Acceptance criteria**

- [ ] New suite `skills/mstack-run/scripts/pick-next-smoke.sh` passes,
      creates all fixtures in its own `mktemp -d` repos, cleans up on exit
      (trap), and never touches the mstack checkout's own plans.
- [ ] Exit-code cases covered: 0 (pick + correct path on stdout), 10 (empty
      dir; all-done), 11 (scoped id missing), 12 scoped (out-of-scope dep)
      AND 12 unscoped (dep-blocked + review-gated backlog, plan 054), 13
      (2-node cycle), 14 (duplicate (goal,id)), 15 (`--goal` slug no plan
      declares).
- [ ] `blocked-by` parsing variants: bare id, zero-padded id, cross-goal
      `slug:id`, quoted `"002"` → loud die (plan 055), garbage/injection
      token → loud die with no side effect.
- [ ] Priority: lower `priority:` beats lower id; absent priority defaults to
      id; non-numeric priority → loud die naming the plan (plan 055).
- [ ] Filters: `needs-review: eng` plan skipped (and its stderr skip note
      present, plan 054); numeric scope filter selects only in-scope; goal
      filter selects only matching goal.
- [ ] Suite registered in BOTH the AGENTS.md smoke list and the pre-commit
      suite loop — edited at the shipped source
      `skills/mstack-run/hooks/pre-commit` (suite list at line 62) and copied
      to `.githooks/pre-commit`, never edited in `.githooks/` only.
- [ ] Script committed executable (`100755`); `script-mode-smoke.sh` covers
      the bit.

## Design

Follow `review-gate-smoke.sh`'s harness shape: a `fail()`/`pass()` counter
pair, one function per case, each case building a fresh temp git repo with
`docs/plans/` fixtures written via heredoc, invoking the picker by absolute
path (`SCRIPT_DIR` resolution, same as other suites), asserting exit code +
stdout path + stderr substrings. Assert exit codes against the sourced lib.sh
CONSTANTS (`$EXIT_ALL_BLOCKED` etc.), not magic numbers, so a renumbering
fails loudly here. The injection case asserts both nonzero exit and the
absence of the side-effect file. Depends on plans 054-056 because it pins
their new behaviors (unscoped 12, loud dies, content-aware plans dir); write
one case for the plan-056 empty-`docs/plans`-shadowing repro too.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next-smoke.sh`: new suite.
- `AGENTS.md`: add to the smoke-suite list (and refresh the pre-commit
  paragraph's stale "all five" count wording).
- `skills/mstack-run/hooks/pre-commit`: add `pick-next-smoke` to the suite
  loop (line 62).
- `.githooks/pre-commit`: refreshed copy of the shipped source (via `cp`, NOT
  `./setup` — see AGENTS.md warning about stray symlinks).

**Out of scope:** any behavior change to `pick-next.sh` itself; covering
`resolve_plan_ref` name resolution (exit 21/22 — `plan-ref-smoke.sh` already
owns that); manifest coverage (plan 076).

## Tasks

1. Write `pick-next-smoke.sh` with the case list from the acceptance
   criteria, one temp repo per case, constants sourced from `lib.sh`.
2. `chmod +x skills/mstack-run/scripts/pick-next-smoke.sh && git update-index --chmod=+x skills/mstack-run/scripts/pick-next-smoke.sh`.
3. Add the suite to AGENTS.md's smoke list; fix the stale suite-count wording
   in the pre-commit paragraph.
4. Add `pick-next-smoke` to the loop in
   `skills/mstack-run/hooks/pre-commit`, then
   `cp skills/mstack-run/hooks/pre-commit .githooks/pre-commit`.
5. Run the new suite plus all existing suites, `bash -n`, `shellcheck`.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/pick-next-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/pick-next-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/pick-next-smoke.sh`
- [cmd] `test -x skills/mstack-run/scripts/pick-next-smoke.sh`
- [cmd] `git ls-files -s skills/mstack-run/scripts/pick-next-smoke.sh | grep -q '^100755'`
- [cmd] `grep -q "pick-next-smoke" AGENTS.md`
- [cmd] `grep -q "pick-next-smoke" skills/mstack-run/hooks/pre-commit && grep -q "pick-next-smoke" .githooks/pre-commit`
- [cmd] `diff skills/mstack-run/hooks/pre-commit .githooks/pre-commit`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh && bash skills/mstack-run/scripts/review-gate-smoke.sh && bash skills/mstack-run/scripts/verify-lint-smoke.sh && bash skills/mstack-run/scripts/health-reach-smoke.sh && bash skills/mstack-run/scripts/wrapup-scan-smoke.sh && bash skills/mstack-run/scripts/plan-ref-smoke.sh && bash skills/mstack-run/scripts/hook-chain-smoke.sh`

## Backlog amendment (2026-07-31)

ORDERING CORRECTED. This plan no longer depends on 054/055/056 and
now runs BEFORE them. As originally sequenced, the picker's only safety net
would have landed after 055 rewrites its internals — including a recursive
`cycle_dfs` port whose silent failure mode is a missed cycle, i.e. a picker
that never terminates.

Write the suite against CURRENT behavior first: exit-code contract,
dependency parsing, ordering, scope filters. That turns 054 and 055 from
unpinned rewrites into changes that must prove they altered only what they
intended. Extend the suite with the new behaviors as part of those plans.
