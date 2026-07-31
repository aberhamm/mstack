---
id: 064
title: Health verdict hardening — a failing tool can no longer yield PASS
status: pending
blocked-by: []
priority: 23
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
---

## Requirements

`skills/mstack-run/scripts/health-check.sh` can emit `VERDICT:PASS` while a
tool it ran reported failure. Three audit-reproduced bugs: (a) the verdict
logic (lines 316-326) fails only on composite < 7.0 or an exact-0 category — a
plan introducing up to 9 fresh TypeScript errors scores typecheck=7 (line 24)
and a composite around 9.2, so `VERDICT:PASS`; the `FAILURES:` list (line 370)
is emitted and consumed by nothing anywhere in the repo. (b) Non-TS toolchains
fail open: typecheck scoring (`score_category`, lines 20-26) counts only the
literal `"error TS"`, so a failing mypy/cargo run (exit 1, count 0) lands in
the `count < 10` branch and scores 7; lint (lines 27-34) scores 7 on nonzero
exit when output lacks the literal words error/warning/warn — ruff's bare
`F401` code lines match neither. (c) REGRESSED detection (lines 328-342) is
wrapped in `if has_jq` with no else branch — silently disabled without jq, the
exact unannounced-degraded-mode anti-pattern AGENTS.md plan 045 documents.
The repo doctrine is "a checker that reported errors is not a checker that
passed"; the current verdict violates it.

**Acceptance criteria**

- [ ] Any tool exiting nonzero marks its category as FAILING, independent of
      the parsed diagnostic count.
- [ ] Nonzero exit with zero parsed diagnostics scores <= 4 in every category
      (evidence of failure with no parse = fail closed, never a 7).
- [ ] Any FAILING typecheck or test category forces `VERDICT:FAIL` regardless
      of the composite. (e2e joins this set when plan 065 wires its scoring.)
- [ ] Without jq, the run announces `REGRESSION_CHECK:skipped-no-jq` in the
      structured output instead of silently skipping regression detection;
      with jq it emits `REGRESSION_CHECK:ok` (or the REGRESSED verdict).
- [ ] The 0-10 composite is still computed and emitted unchanged as a
      dashboard signal; what changed is what gates.
- [ ] `FAILURES:` output format is unchanged (plan 067 will pin consumers).

## Design

Keep `score_category` as the 0-10 scorer but make it fail-closed: in each
category, when `exit_code != 0` and the parsed count is 0, return 4, not 7 or
10 (the count heuristics only refine a *parsed* failure downward). Track
category failure separately from score in `cmd_run`: the existing
`[ "$exit_code" -ne 0 ]` check (lines 286-288) already builds `failures`; add
a parallel per-category failing flag (e.g. `f_typecheck=true`). The verdict
block then becomes: FAIL if composite < 70, OR any active category scored 0,
OR any of typecheck/test is flagged failing. Lint/deadcode/shell failing
alone still flows through composite/zero rules (they stay advisory), but
their <= 4 fail-closed score already drags the composite. For (c), move the
regression check out of the silent `if has_jq` shape: with jq, behavior is
unchanged; without jq, emit `REGRESSION_CHECK:skipped-no-jq` as a structured
output line per the AGENTS.md "say which mode it is in" rule.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/health-check.sh`: `score_category` fail-closed
  scoring; `cmd_run` failing flags, verdict forcing, `REGRESSION_CHECK:` line.

**Out of scope:** e2e scoring and weight unification (plan 065); the smoke
suite pinning these behaviors (plan 067); any change to `result-gate.sh` or
to the legal verdict set (`PASS`/`FAIL`/`REGRESSED`/`NO-TOOLS`/
`NONE-DECLARED` stays closed); consuming `FAILURES:` elsewhere.

## Tasks

1. In `score_category`, add the fail-closed rule per category: nonzero exit
   with parsed count 0 returns 4 (typecheck, lint, deadcode, shell) — test
   already handles nonzero exit explicitly, keep its pass-rate logic.
2. In `cmd_run`, record per-category failing flags alongside the existing
   `failures` string when `exit_code -ne 0`.
3. Rewrite the verdict block: force FAIL on any failing typecheck/test flag,
   keeping the composite < 70 and any-zero rules.
4. Restructure the regression check to announce its mode: emit
   `REGRESSION_CHECK:ok` / `REGRESSION_CHECK:skipped-no-jq` in the structured
   output; keep the REGRESSED drop >= 1.0 logic unchanged under jq.
5. Run syntax, shellcheck, and all existing smoke suites.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/health-check.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/health-check.sh`
- [assert] `grep -c "REGRESSION_CHECK" skills/mstack-run/scripts/health-check.sh` output is a number >= 2
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/health-reach-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [manual] in a temp repo with a configured failing typecheck command that
  prints no "error TS" lines, `health-check.sh run` emits `VERDICT:FAIL`

## Backlog amendment (2026-07-31)

This plan now ABSORBS plan 065 (wire e2e into health scoring; single
weight source), which is skipped as folded. Both edited the same twenty lines
of `health-check.sh` — `score_category` and the verdict block — so splitting
them forced a manual merge between two review cycles for one edit.

Carry over from 065:
- Add an `e2e` case to `score_category` and an `e2e` branch to the
  score-assignment `case`; today the e2e score is computed and discarded
  (falls through to `*) echo 0`), so a failing e2e suite yields PASS 10.0.
- Consolidate the default weights, which currently disagree across three
  files: `config.sh` (20/15/25/20/10/10), `health-check.sh` (25/20/30/15/10,
  no e2e), and `mstack-config/SKILL.md` (documents the health-check.sh set,
  which sums to 100 only because e2e is missing).
- `README.md` claims e2e weight "is redistributed if no framework is
  detected" — not implemented anywhere. Either implement or delete the claim.

## Triage amendment (2026-07-31)

ABSORBS the two live pins from plan 067, which is now dropped. All
eight `result-gate.sh assert-health-result` branches were hand-probed on
2026-07-31 and are correct, and no remaining plan modifies `result-gate.sh`, so
a separate suite for it pins frozen, already-correct code. Delete the "Out of
scope: the smoke suite pinning these behaviors (plan 067)" line and carry these
two regression cases here instead:

1. a typecheck/test command exiting nonzero must force `VERDICT:FAIL` — today
   a failing mypy, ruff, or cargo run scores 7 and yields `VERDICT:PASS`
2. `REGRESSION_CHECK:skipped-no-jq` must be emitted when jq is absent — the
   REGRESSED block is inside `if has_jq` with no else, so it silently no-ops

Also carry the 5-line dead-code deletion from dropped plan 066: `json_get`
2-level fallback uses GNU-only 3-arg `match($0,/re/,a)`, which is a hard parse
error on macOS awk, and the 3-level path dead-ends at `*) return 1`. Delete the
dead branch and return with a stderr note rather than leaving a fallback that
cannot run.
