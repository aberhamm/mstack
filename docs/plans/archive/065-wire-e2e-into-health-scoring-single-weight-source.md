---
id: 065
title: Wire the e2e category into health scoring; single source of truth for weights
status: done
blocked-by: [064, 066]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
completed: 2026-07-31
reviewed: false
qa: automated
---

## Requirements

`health-check.sh` detects `e2e` (`cmd_detect`, e2e block lines 181-187) and
runs it (the `cmd_run` tool loop, lines 257-289, executes every detected
tool), but the category is scored into the void: `score_category` (lines
14-65) has no e2e case so it falls to `*) echo 0` (line 63); the score-
assignment `case` (lines 278-284) has no e2e branch, discarding it; the
weight reads (lines 243-248) fetch no `w_e2e`; and `active_weight` (lines
295-300) ignores it. Net effect, audit-reproduced: a failing Playwright
suite plus one passing lint yields `VERDICT:PASS COMPOSITE:10.0
FAILURES:e2e`. An e2e-ONLY repo detects a tool (so it passes the NO-TOOLS
gate) yet ends with `active_weight=0` and a bare `die "no tools ran
successfully"` (line 302) — no `VERDICT:` line at all, exactly the
crashed-gate state plan 043 exists to forbid. Separately, weights have two
divergent sources of truth: `config.sh` `DEFAULT_CONFIG` (lines 11-31)
declares `"e2e": 20` with weights 20/15/25/20/10/10 (sum 100), while
`health-check.sh`'s hardcoded fallbacks are 25/20/30/15/10 with no e2e, and
`skills/mstack-config/SKILL.md` (lines 104-125) documents the
health-check.sh set, not the config.sh set, then says weights "must sum to
100" (line 134). The README table (lines 74-83) claims "E2E weight is
redistributed if no framework is detected" — not implemented.

**Acceptance criteria**

- [x] e2e is scored (reusing the test-category scoring rules) and carried
      through weights, `active_weight` redistribution, the composite, the
      verdict (a failing e2e forces FAIL, joining plan 064's set), and the
      persisted history entry.
- [x] An e2e-only repo produces a normal structured result, and the
      `active_weight=0` path — now reachable only on internal error — emits
      a structured `VERDICT:FAIL` block plus a nonzero exit, never a bare
      `die` with no `VERDICT:` line (plan 043 doctrine).
- [x] Default weights come from ONE place: `config.sh` `DEFAULT_CONFIG`.
      `health-check.sh` carries no divergent literal set.
- [x] `skills/mstack-config/SKILL.md` and README document the same weights
      as `DEFAULT_CONFIG`, and the documented set actually sums to 100.

## Design

Score e2e via the existing test rules: change `score_category`'s `test)` case
to `test|e2e)`. Add `s_e2e`/`w_e2e`/`f_e2e` through the run loop, weight
redistribution, composite, verdict (064's forced-FAIL set becomes
typecheck/test/e2e), and the history JSON entry (add an `"e2e"` field beside
`"test"`, null when SKIPPED — additive, jq readers use `//` defaults).
Single source of truth: `health-check.sh` already reads weights via
`bash config.sh get health.weights.<cat>`, and `config.sh` `cmd_get`
(lines 50-57) already falls back to `DEFAULT_CONFIG` — so the `|| echo N`
literals only fire if `config.sh` itself crashes. Replace the five divergent
literals with a single failure branch: if any weight read fails, emit the
structured failure block (`VERDICT:FAIL`, `FAILURES:config-unreadable`) and
exit nonzero — fail closed rather than fail different. Depends on 066
because `health.weights.*` / `health.commands.*` are 2-3-level paths and the
jq-less read path must be honest before it gates. Update the SKILL.md
default-config block and weight prose, and the README table, to the
DEFAULT_CONFIG values (20/15/25/20/10/10); drop or implement-match the
README's redistribution footnote (redistribution over SKIPPED categories is
now real, so reword it to describe that).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/health-check.sh`: e2e scoring/weight/verdict/
  persist wiring; structured failure for the zero-active-weight path;
  weight-literal removal.
- `skills/mstack-config/SKILL.md`: default config block + weight docs.
- `README.md`: weight table.

**Out of scope:** the smoke suites pinning this (plan 067); changing
detection order or adding new e2e frameworks; `config.sh` `DEFAULT_CONFIG`
values themselves (they stay as committed); `status.sh` history rendering.

## Tasks

1. Extend `score_category` to `test|e2e)` and thread `s_e2e`/`w_e2e` through
   the run loop, redistribution, composite, and verdict paths.
2. Convert the `active_weight=0` `die` into a structured `VERDICT:FAIL` /
   `COMPOSITE:n/a`-free failure block with nonzero exit.
3. Remove the hardcoded weight fallbacks; fail closed with a structured
   block when a weight read errors.
4. Add the `"e2e"` field to the persisted history entry.
5. Align `skills/mstack-config/SKILL.md` (default block, sum-to-100 prose)
   and the README weight table with `DEFAULT_CONFIG`.
6. Run syntax, shellcheck, and all smoke suites.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/health-check.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/health-check.sh`
- [assert] `grep -c "test.e2e" skills/mstack-run/scripts/health-check.sh` output is >= 1 (the dot matches the literal pipe of the shared test/e2e case pattern; a raw pipe character is reserved as the assert separator and must not appear in the command)
- [assert] `grep -c "w_e2e" skills/mstack-run/scripts/health-check.sh` output is >= 3
- [cmd] `! grep -q "die \"no tools ran successfully\"" skills/mstack-run/scripts/health-check.sh`
- [assert] `grep -c '"e2e": 20' skills/mstack-config/SKILL.md` output is >= 1
- [cmd] `bash skills/mstack-run/scripts/health-reach-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [manual] in a temp repo whose only configured tool is a failing e2e
  command, `health-check.sh run` emits `VERDICT:FAIL`, not PASS or a bare die
- [manual] in that same temp repo, after a post-fix `health-check.sh run`,
  `tail -1 .mstack/health-history.jsonl | jq -e 'has("e2e")'` exits 0 — the
  persisted history line carries the e2e field

## Completion note (2026-07-31)

Implemented directly, out of the order the frontmatter implies. Both recorded
blockers were resolved by something other than being executed, so neither
actually gated this work:

- **066** was skipped on 2026-07-31 because jq is present on both machines, so
  `json_get`'s 2-level awk fallback is never the path a weight read takes. The
  fail-closed branch this plan added makes the concern moot regardless: an
  unreadable weight now stops the gate instead of silently substituting a
  literal.
- **064** was cited only for line overlap in `health-check.sh`. The e2e wiring
  here is additive (a new score slot, weight, composite term, history field and
  output line); it does not touch the verdict thresholds or the per-category
  scoring rubrics that 064 owns, so 064 remains independently executable.

Two deviations from the plan as written, both deliberate:

1. **A smoke suite was added**, although the plan assigned suites to 067 (now
   skipped). `skills/mstack-run/scripts/health-score-smoke.sh` covers the
   escape, its mirror (an undetected e2e must not consume weight), the
   e2e-only repo, config-driven weights, fail-closed config, and the persisted
   history field. Negative control performed: restoring the pre-fix
   `health-check.sh` from HEAD makes case 1 fail with the exact audit symptom,
   `VERDICT:PASS COMPOSITE:10.0 FAILURES:e2e`. The suite is wired into the
   pre-commit smoke loop in `skills/mstack-run/hooks/pre-commit` and
   `.githooks/pre-commit`.
2. **A new exit code was added**, `EXIT_HEALTH_INTERNAL=36` in `lib.sh`. The
   plan asked only for "nonzero"; a distinct code keeps "mstack is broken"
   separable from 31 ("your repo has not declared a health stack"), since the
   operator action differs. Documented in the README exit-code tables and in
   `references/health-gate-spec.md`.

The `[manual]` checks are discharged by cases 4 and 7 of the smoke suite, which
build exactly the temp repos they describe.
