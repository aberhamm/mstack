# Step 5: Verification gate (mstack-code-health)

Run the health check script. It discovers tools, runs them, scores each
category 0-10, computes a weighted composite, persists to history, and
returns a structured verdict:

```bash
PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
```

Parse the output; each line is `KEY:VALUE`:

```
VERDICT:PASS
COMPOSITE:9.1
TYPECHECK:10
LINT:8
TEST:10
E2E:9
DEADCODE:7
SHELL:10
DURATION:23
FAILURES:none
```

A category with no detected tool reports `SKIPPED` and its weight is
redistributed over the categories that ran, so a repo without Playwright is
not penalised for the `e2e` line.

**Progress:** After parsing the health output, print:
```
[mstack] ├─ Health gate: <COMPOSITE>/10 (<VERDICT>)
```

The legal VERDICT values are exactly `PASS`, `PASS-WAIVED`, `FAIL`,
`REGRESSED`, `NO-TOOLS`, and `NONE-DECLARED`. There is no `SKIP`, and no other
value may be reported.

Act on the VERDICT line:
- **PASS** (composite >= 7.0, no category at 0) → proceed to Step 5b
- **NONE-DECLARED** (zero tools detected, and the repo declares `- none:` under
  `## Health Stack` in AGENTS.md/CLAUDE.md) → the gate is satisfied by explicit
  declaration; `COMPOSITE` is the literal `n/a`. Proceed to Step 5b.
- **PASS-WAIVED** (the categories still scored pass, and at least one failing
  category was `WAIVED` by a valid health waiver — see below) → proceed to Step
  5b exactly as for PASS. Report `HEALTH_WAIVED` from the `WAIVED:` line.
  `COMPOSITE` is `n/a` only when every category that ran was waived and at
  least one by a passing baseline-delta comparison.
- **FAIL** (composite < 7.0, or any category at 0) → enter investigation
- **REGRESSED** (composite dropped >= 1.0 from previous) → enter investigation
- **NO-TOOLS** (zero tools detected across ALL categories, and the repo never
  declared it has none — exit code 31) → **hard failure, not a skip.** Absence
  of configuration means "not yet declared", never "nothing required". Step 7
  failure path with reason `health-gate-unavailable`.
- **FAIL with `FAILURES:config-unreadable` or `FAILURES:internal-no-active-weight`**
  (exit code 36) → the gate could not score the repo for a reason that is
  mstack's fault: the category weights were unreadable, or a detected category
  carried no weight into the composite. `COMPOSITE` is the literal `n/a`. Step 7
  failure path with reason `health-gate-unavailable`; fix the config (or the
  bug) rather than re-running.

## Health waivers (plan 099)

A repo that fails the gate for reasons a plan did not cause (for example, every
category already fails at baseline) can be waived per plan and per category.
The waiver is a `waivers:` frontmatter entry written with
`scripts/waiver.sh waive`, and it counts only when git history shows:

- it was committed by an approver listed in the tracked
  `<plans dir>/waivers/APPROVERS` file **before** the waiver commit (and still
  listed now — removal revokes);
- the waiver commit is **strictly before the plan's latest claim commit**, is
  not a merge or root commit, and the entry has not changed since;
- it has not expired (`expires` at most 30 days after `date`);
- for `baseline-delta`, the committed baseline (from
  `waiver.sh capture-baseline`, run once on a clean checkout) existed at the
  waiver commit, is unchanged, and was written by the same extractor version.

Health-check reads waivers from `HEAD` only (never the working tree), and only
when `PLAN_ID` is set. Per failing category:

- **blanket** valid → `<CAT>:WAIVED`. Nothing was measured.
- **baseline-delta** valid and the full (untruncated) output has no failure
  identity beyond the baseline multiset → `<CAT>:WAIVED`, measured. Extractors
  exist only for `typecheck` (`tsc-v1`) and `shell` (`shellcheck-v1`); every
  other category can only be blanket-waived.
- delta finds new identities → scored normally, `FAILURES` gains
  `waiver-delta-regressed:<cat>`; unparseable output → `waiver-noncomparable:<cat>`;
  an unhonoured waiver → `waiver-invalid:<cat>`.

A `WAIVED` category is excluded from the composite like `SKIPPED` (never scored
10). If every category that ran is waived and none by delta, the verdict is
`FAIL` with `FAILURES:all-categories-waived`. The output gains a
`WAIVED:<cat>:<mode>,...` line (`WAIVED:none` otherwise).

Step 7a re-checks every listed waiver itself
(`result-gate.sh assert-health-result <file> --plan "$NEXT"`), the pre-commit
hook refuses a done commit whose waiver fails the history rule, and
`review-gate.sh audit` lists every plan completed under a waiver. There are no
signatures: an agent with a shell can still author the approver, waiver and
claim commits itself. The gain is that a waiver is deliberate, sits in history,
and is listed afterwards.

## On a crashed gate: hard failure, never a skip

If the command exits nonzero with no parseable `VERDICT` line — a missing
binary, a malformed config, a syntax error in a tool command — the health gate
is **unavailable**, not passing. There is nothing to interpret and nothing to
improvise: take the Step 7 failure path with reason `health-gate-unavailable`.

This branch exists because its absence was the real bug: with no branch for
"crashed", a worker invented `HEALTH_VERDICT: SKIP` and the orchestrator marked
the plan done over a gate that never ran. `mstack-run` Step 7a now re-parses the
health fields deterministically (`scripts/result-gate.sh assert-health-result`),
so a `pass` result carrying anything other than `PASS`/`NONE-DECLARED` (or a
`PASS-WAIVED` whose waivers re-check valid) is rejected regardless of what this
prose says — which is the point: the rule is enforced by a parser, not by an
agent remembering to obey it.

## On FAIL or REGRESSED: mstack-investigate

Instead of retrying blindly, run structured debugging using
mstack-investigate logic:

1. Read the plan file for context (acceptance criteria, expected files)
2. Collect symptoms from health output (which tools failed, exact errors)
3. **Phase 1**: Root cause investigation: trace code, check changes, search learnings
4. **Phase 2**: Pattern analysis: match against known failure patterns
5. **Phase 3**: Hypothesis testing with mandatory reflection before each attempt:
   ```
   ATTEMPT N/3
   Previous: <what was tried>
   Hypothesis: <specific, testable claim>
   Am I repeating myself: <yes/no>
   ```
6. **Phase 4**: Minimal fix + regression test

**Category-aware strike rule:** 3 strikes per root cause category, max 3
categories (9 total attempts). After all categories exhausted, mark the
plan failed with detailed diagnosis. Do not enter a retry loop.

If investigation succeeds (FIXED): re-run the health check to confirm,
then proceed to Step 5b.

If investigation fails (all categories exhausted — up to 3 strikes each
across at most 3 categories): Step 7 failure path.
