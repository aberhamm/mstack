---
id: 047
title: health gate must prove it runs the tests a plan adds
status: pending
blocked-by: []
priority:
goal: pipeline-hardening
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
---

## Requirements

A plan can add a test that the configured health-gate command never executes,
and nothing notices. Observed live: a repo's `.mstack/config.json` test command
carried a `-k` filter that would have **excluded
`test_curl_cffi_impersonation_guard.py` entirely**. The gate ran, reported
green, and covered none of the new code.

This is plan 043's doctrine one level up. 043 fixed *zero tools detected* —
undeclared absence reading as "nothing required". This is the subtler case:
tools ARE detected, the command DOES run, and its selector silently excludes the
code under test. A gate that runs over the wrong files is not a gate that
passed, exactly as a check that cannot run is not a check that passed (046).

**Acceptance criteria**

- [ ] A deterministic check answers: "would the configured test command execute
      the test files this plan declares it adds?"
- [ ] It runs WITHOUT executing the suite — collection/enumeration only, so it
      is cheap enough to run at doctor time, before implementation.
- [ ] A declared-but-unreachable test file is a **blocking** finding naming the
      file and the selector that excludes it.
- [ ] Fails closed: if reachability cannot be determined (unknown runner, no
      collection mode), report UNKNOWN and treat as not-verified — never as
      covered. Silence here rebuilds the defect.
- [ ] Wired into `mstack-plan-doctor` so it runs per plan, and covered by a
      smoke suite.

## Design

Reuse, do not reinvent: `verify-lint.sh` already shells `pytest --collect-only`
and parses the collected set (`_pytest_collects`). The same mechanism answers
reachability — collect with the CONFIGURED command (filters included) and ask
whether the plan's declared new test files appear in the collected set.

Test files a plan adds are read from its `**Files expected to change:**` list,
filtered to test-shaped paths (`test_*.py`, `*_test.go`, `*.test.ts`, `*_spec.rb`).

Runner support, fail-closed by tier: `pytest --collect-only -q` (full support);
`go test -list .`, `vitest --run --reporter=json --coverage=false`, `jest
--listTests` (best-effort); anything else → UNKNOWN.

**Files expected to change:**

- `skills/mstack-run/scripts/health-reach.sh`: new; `reach <plan>` reports
  REACHABLE / UNREACHABLE / UNKNOWN per declared test file.
- `skills/mstack-run/scripts/health-reach-smoke.sh`: new; must include a
  `-k`-filter fixture reproducing the observed escape.
- `skills/mstack-run/scripts/lib.sh`: new exit code (next free: 34).
- `skills/mstack-plan-doctor/SKILL.md`: wire it in; UNREACHABLE blocks, UNKNOWN
  reports.
- `AGENTS.md`: doctrine note extending the plan-043 section.

**Out of scope:** changing anyone's test command; running the suite; coverage
measurement (reachability is not coverage — a collected test can still assert
nothing); non-test files.

## Tasks

1. Add the exit code to `lib.sh`.
2. Write `health-reach.sh`: parse declared test files, collect with the
   configured command, diff, report per file.
3. Write the smoke suite, including the `-k`-exclusion fixture.
4. Wire into plan-doctor with blocking/reporting semantics.

## Verification

Checks:

- [cmd] `test -f skills/mstack-run/scripts/health-reach.sh`
- [cmd] `test -x skills/mstack-run/scripts/health-reach.sh`
- [cmd] `bash skills/mstack-run/scripts/health-reach-smoke.sh`
- [assert] `grep -c "UNKNOWN" skills/mstack-run/scripts/health-reach.sh`
- [cmd] `grep -q "health-reach" skills/mstack-plan-doctor/SKILL.md`
- [manual] confirm the `-k` fixture reproduces the original escape before the fix
