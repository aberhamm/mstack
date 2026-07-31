---
id: 063
title: cover the untested enforcement surfaces with a dedicated smoke suite
status: pending
blocked-by: [061, 062]
priority: 46
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Grep across all seven suites confirms these documented enforcement behaviors
have ZERO test coverage today (re-checked against the working tree; plans
058-062 add their own regression cases — dedupe, own whatever remains):

- `assert-committed` (plan 037): exempt-when-unreviewed, approved+dirty → 25,
  approved+clean → 0, unreadable-git-status fail-closed.
- `assert-work-committed` (plan 039): clean-vs-baseline pass, plan-attributable
  dirt → 28, MISSING baseline → 28 (fail closed), and the rename/space-in-path
  porcelain shapes that motivated `porcelain_paths` (lib.sh lines 623-657).
- The pre-push REJECTION paths (`cmd_hook_pre_push`, review-gate.sh lines
  929-988): completion tag for a non-completable plan; tag whose plan file is
  missing (lines 958-961); dirty-tree guard (lines 971-977).
  hook-chain-smoke.sh only exercises the benign pass+chain path.
- The pre-commit FALLBACK fail-closed done-transition (shipped source
  `skills/mstack-run/hooks/pre-commit` lines 104-126 — verified): with
  review-gate.sh unreachable a staged done-transition is refused;
  hook-chain-smoke test 5 only covers the ordinary-commit chain-through.
- `record`'s `by=` injection guard (review-gate.sh line 577).
- `backfill --all` (only single-plan backfill is tested).
- `init.sh`'s hook install: `.githooks/` population, `core.hooksPath` set, and
  `mstack.priorHooksPath` capture (init.sh lines 85-127) — hook-chain-smoke
  plants that config by hand, so the install path itself is untested.

**Acceptance criteria**

- [ ] Every behavior above has at least one asserting smoke case (exact exit
      codes, not just nonzero, where a code is contracted).
- [ ] Cases already added by plans 058/059/062 (record fail-closed, invalid
      tokens, laundering, rename/deletion, demotion) and 060/061 (audit,
      assert-hook-installed) are NOT duplicated — verify what landed, then
      cover only the remainder.
- [ ] Any new suite is registered in AGENTS.md's smoke list, the pre-commit
      hook's suite loop (SHIPPED SOURCE `skills/mstack-run/hooks/pre-commit`
      line 62, then copied to `.githooks/pre-commit`), and is committed
      executable (100755) so script-mode-smoke passes.
- [ ] All suites green.

## Design

One new `skills/mstack-run/scripts/enforcement-smoke.sh` rather than growing
the two existing suites past readability. Justification: these cases all need
throwaway git repos with distinctive fixtures (baselines, tags, an isolated
HOME for skill resolution, a scripts-tree copy for init), a different harness
shape from review-gate-smoke's static-fixture style; and the pre-commit suite
loop reports per-suite, so a focused suite keeps failures attributable. Reuse
hook-chain-smoke's proven patterns: `HOME` shim symlinking the working-copy
skill dir, hand-fed ref lines on stdin for pre-push, review-gate-smoke's
`run_rc` exact-exit-code assertion, and a counter file for subshell-safe
pass counts.

Pre-push rejection cases drive `.githooks/pre-push` exactly as git would,
piping a `refs/tags/mstack/plan-900-done <sha> ...` ref line into
`bash .githooks/pre-push origin url` — no real remote needed. The fallback
fail-closed case uses an EMPTY home (no resolvable review-gate.sh) plus a
staged done-transition and asserts the refusal exits 1; contrast case:
an ordinary commit under the same empty home passes.
The init.sh case runs `init.sh` in a repo with a pre-existing local
`core.hooksPath` pointing at a planted dir and asserts `.githooks/` is
populated from the shipped hooks, `core.hooksPath=.githooks`, and
`mstack.priorHooksPath` captured (and NOT captured when the prior value was
already `.githooks`). `assert-work-committed` cases write the documented
`.mstack/pre-dirty-<id>.txt` baseline directly and include a `git mv` rename
and a path with a space, asserting both porcelain shapes classify correctly.

First task is the dedupe audit: read what plans 058-062 actually added to the
existing suites and strike covered items rather than re-testing them.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/enforcement-smoke.sh`: new suite (100755:
  `chmod +x` + `git update-index --chmod=+x`).
- `skills/mstack-run/scripts/hook-chain-smoke.sh`: only if a case fits its
  existing harness better than the new suite.
- `skills/mstack-run/hooks/pre-commit` + `.githooks/pre-commit`: add
  enforcement-smoke to the suite loop (edit shipped source, then `cp` — never
  `.githooks/` only; do not run `./setup` from ~/dev/mstack).
- `AGENTS.md`: add the suite to the Development Commands smoke list.

**Out of scope:** changing any behavior under test (a case exposing a real
defect gets a new plan — record it, do not silently patch), CI wiring, the
`.mstack/reviews/*.json` cache.

## Tasks

1. Dedupe audit: enumerate cases added by plans 058-062, produce the final
   remainder list this suite owns.
2. Write `enforcement-smoke.sh` harness (temp repos, HOME shim, counter,
   `run_rc`) and the `assert-committed` + `assert-work-committed` cases,
   including missing-baseline, rename, and space-in-path.
3. Add the pre-push rejection trio (non-completable tag, missing plan file,
   dirty tree) and a benign-tag positive control.
4. Add the fallback pre-commit fail-closed done-transition case, the `by=`
   injection-guard case (`record ... 'x verdict=approved'` must die), and
   `backfill --all` across a multi-plan fixture dir.
5. Add the init.sh install cases (hooks copied, hooksPath set, prior path
   captured / not self-captured).
6. Register the suite (AGENTS.md + hook source + `cp` to `.githooks/`), set
   the executable bit in the index, run all suites.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/enforcement-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/enforcement-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/enforcement-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `git ls-files -s skills/mstack-run/scripts/enforcement-smoke.sh` — mode is 100755
- [assert] `grep -c "enforcement-smoke" skills/mstack-run/hooks/pre-commit` — registered in the shipped hook source
- [cmd] `cmp skills/mstack-run/hooks/pre-commit .githooks/pre-commit`
- [assert] `grep -c "enforcement-smoke" AGENTS.md` — registered in the docs
