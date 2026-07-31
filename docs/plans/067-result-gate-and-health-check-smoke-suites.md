---
id: 067
title: result-gate-smoke and health-check-smoke suites
status: skipped
blocked-by: []
priority: 21
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "all 8 result-gate branches verified correct today and no pending plan touches result-gate.sh; criteria still reference the skipped 065; two live pins folded into 064"
---

## Requirements

Two enforcement spines have zero tests. (a) `result-gate.sh
assert-health-result` is plan 043's entire deterministic mechanism — the
thing that stops a worker improvising `HEALTH_VERDICT: SKIP` — and no suite
exercises a single branch of it. (b) `health-check.sh`'s verdict computation
(NO-TOOLS vs NONE-DECLARED, redistribution, REGRESSED) is likewise untested,
and plans 064/065 just changed it; without regression pins, the next edit
can silently reopen the failing-tool-yields-PASS hole. Add two suites in the
existing smoke style: self-contained, deterministic, seconds to run.

**Acceptance criteria**

- [ ] `result-gate-smoke.sh` pins every branch of `cmd_assert_health_result`
      (result-gate.sh lines 50-126): missing STATUS field → exit 30;
      `STATUS: PASS` (uppercase, case-sensitive match fails) → 30; garbled
      STATUS → 30; `STATUS: fail` and `STATUS: blocked` → 0 (no health
      fields required); `STATUS: pass` with no HEALTH_VERDICT → 30; with
      `HEALTH_VERDICT: SKIP` → 30; lowercase/garbled verdict → 30;
      `HEALTH_VERDICT: FAIL`/`REGRESSED`/`NO-TOOLS` with pass → 30; missing
      HEALTH_COMPOSITE → 30; `HEALTH_COMPOSITE: n/a` accepted ONLY alongside
      `NONE-DECLARED` (with PASS → 30); non-numeric composite → 30; fields
      appearing after `SUMMARY:` are ignored (block cut at line 71); input
      with and without the `---MSTACK-RESULT---` delimiters; first-occurrence
      field wins over later free-text duplicates.
- [ ] `health-check-smoke.sh` pins, in throwaway git fixtures: NO-TOOLS →
      `VERDICT:NO-TOOLS` + exit 31; a tracked `## Health Stack` `- none:`
      declaration → `VERDICT:NONE-DECLARED` + exit 0; weight redistribution
      over SKIPPED categories; REGRESSED on a >= 1.0 composite drop (jq
      present); the 064 pins (a nonzero-exit
      typecheck or test tool forces `VERDICT:FAIL`; a nonzero-exit
      lint-only tool scores <= 4 but does NOT by itself force FAIL —
      lint/deadcode/shell stay advisory, pin that too; `REGRESSION_CHECK:`
      mode line present); the 065 pins (e2e scored into the composite and
      into the forced-FAIL set; an e2e-only repo emits a structured
      verdict, never a bare die).
- [ ] Both suites are committed executable (100755) and registered in
      AGENTS.md's smoke list and the pre-commit hook source's suite loop,
      with the `.githooks/pre-commit` copy refreshed.

## Design

Follow the existing suite pattern (`review-gate-smoke.sh` et al.): a
`run_case` helper asserting exit code and a grep on output, temp dirs via
`mktemp -d` with cleanup traps, no network, no dependence on the host repo's
state. result-gate cases feed here-doc result blocks via stdin and via a
file argument (both entry paths, result-gate.sh lines 51-57). health-check
cases build a minimal `git init` fixture per case, writing an `AGENTS.md`
(with or without `## Health Stack`) and a `.mstack/config.json` declaring
`health.commands.<cat>` entries that point at tiny always-pass /
always-fail stub scripts, so no real toolchain is needed; assert on the
emitted `VERDICT:`/`COMPOSITE:`/`FAILURES:`/`REGRESSION_CHECK:` lines and
exit codes (31 = `EXIT_HEALTH_NO_TOOLS`, lib.sh line 75; 30 =
`EXIT_RESULT_HEALTH_INVALID`, line 70). REGRESSED case seeds
`.mstack/health-history.jsonl` with a high prior score, then runs a lower-
scoring pass. Read the current `result-gate.sh` and `health-check.sh` at
implementation time and enumerate their actual branches — the lists above
are the floor, not the ceiling. Register both suites: AGENTS.md smoke list,
the `for s in ...` loop in `skills/mstack-run/hooks/pre-commit` (line 62),
then copy the hook source to `.githooks/pre-commit` (source first, per
AGENTS.md — a `.githooks/`-only edit gets clobbered).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/result-gate-smoke.sh`: new suite.
- `skills/mstack-run/scripts/health-check-smoke.sh`: new suite.
- `skills/mstack-run/hooks/pre-commit`: add both to the suite loop.
- `.githooks/pre-commit`: refreshed copy.
- `AGENTS.md`: register both suites in the smoke-suite list.

**Out of scope:** changing `result-gate.sh` or `health-check.sh` behavior
(if a case exposes a real bug, record it as a finding and pin current
behavior or block — do not silently "fix" the spine inside a test plan);
testing `mstack-run`'s prose orchestration of the gate.

## Tasks

1. Write `result-gate-smoke.sh` covering the enumerated branch matrix, stdin
   and file-argument entry paths included.
2. Write `health-check-smoke.sh` with per-case git fixtures and stub tool
   commands covering the verdict/exit matrix and the 064/065 regression pins.
3. `chmod +x` both and stage the executable bit with
   `git update-index --chmod=+x`.
4. Register both in AGENTS.md and `hooks/pre-commit`; copy the hook to
   `.githooks/pre-commit`.
5. Run both new suites plus the full existing suite set.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/result-gate-smoke.sh skills/mstack-run/scripts/health-check-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/result-gate-smoke.sh skills/mstack-run/scripts/health-check-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/result-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/health-check-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `git ls-files -s skills/mstack-run/scripts/result-gate-smoke.sh` output contains 100755
- [assert] `git ls-files -s skills/mstack-run/scripts/health-check-smoke.sh` output contains 100755
- [cmd] `grep -q "result-gate-smoke" skills/mstack-run/hooks/pre-commit && grep -q "health-check-smoke" skills/mstack-run/hooks/pre-commit`
- [cmd] `grep -q "result-gate-smoke" .githooks/pre-commit && grep -q "result-gate-smoke" AGENTS.md`
- [cmd] `grep -q "health-check-smoke" skills/mstack-run/hooks/pre-commit && grep -q "health-check-smoke" AGENTS.md`

## Backlog amendment (2026-07-31)

ORDERING CORRECTED. This plan no longer depends on 064 and now runs
BEFORE it, for the same reason as 057: 064 is surgery on the exact twenty
lines that produce the reproduced "failing tests yield PASS" bug, and it
would otherwise ship with nothing pinning it.

Scope down from the exhaustive branch matrix to the cases that matter, all
written against current behavior:
1. a nonzero-exit test command must force FAIL (currently scores 7 and passes)
2. a failing e2e suite must force FAIL (currently discarded, yields PASS 10.0)
3. `HEALTH_VERDICT: SKIP` must be rejected by `result-gate.sh` with exit 30
