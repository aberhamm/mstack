---
id: 085
title: dedupe doctrine so each invariant has one canonical statement
status: pending
blocked-by: []
priority: 40
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

The review-gate/health-gate invariant family is told in full in AGENTS.md,
again in `mstack-run` Step 7a, again in
`skills/mstack-run/references/review-spec.md` + `implement-spec.md`, and
again in status/backlog/doctor sections — and the audit's Tier-1/2 drift
findings were overwhelmingly COPIES DISAGREEING. After 084 shrinks Step 7a,
do the editorial pass so each invariant has exactly one canonical statement
and every other site carries only the action plus a pointer.

Current working-tree line counts: `skills/mstack-run/SKILL.md` 1268,
`skills/mstack-plan-doctor/SKILL.md` 1397 (pre-084; 084 takes part of
mstack-run's cut).

**Acceptance criteria**

- [ ] AGENTS.md holds the one canonical statement per invariant (review gate,
      layered enforcement, approved-committed, work-committed, health gate,
      scaffold/authored); SKILL bodies carry only the action ("run X; on exit
      23 do Y — semantics in AGENTS.md §...").
- [ ] mstack-run's picker exit-code case statement (SKILL.md:403-437) no
      longer restates its own table (SKILL.md:390-399) comment-by-comment —
      one of the two carries the meaning, the other refers to it.
- [ ] SKILL_DIR resolution is stated once per skill and referenced
      thereafter: mstack-run currently has 3 `SKILL_DIR=` assignment sites,
      plan-doctor has 20 `SKILL_DIR=`/`RUN_SKILL_DIR=` assignment lines
      (~10 resolver blocks, e.g. lines 39, 268, 300, 486, 661, 711).
- [ ] The tag-stranding war story is told once: mstack-run tells it at both
      step 9 (SKILL.md:1026-1037) and step 11 (SKILL.md:1061-1074); keep one
      full telling, the other becomes a pointer. (If 084 moved these lines,
      re-locate by the `--follow-tags` anchor text.)
- [ ] plan-doctor's two inline agent-prompt templates — per-plan agent
      (SKILL.md:736-803) and cross-plan consistency agent (SKILL.md:804-846)
      — move to `skills/mstack-plan-doctor/references/` files, mirroring
      mstack-run's `references/subagent-prompt.md` pattern (the asymmetry is
      documented convention drift).
- [ ] plan-doctor Step 2's scoring rubrics + auto-fixes (Dimensions through
      trap-resistance auto-fix, SKILL.md:416-653) move to a reference; only
      the composite formula (currently :500-515) and always-apply thresholds
      stay inline.
- [ ] No invariant SEMANTICS change anywhere: the canonical statements are
      grep-pinned (see Verification) and all smoke suites pass.
- [ ] Line-count reduction ~20-25% on both big SKILL.md files, measured
      against each file's post-084 state: plan-doctor 1397 → ≤ ~1120;
      mstack-run ≤ ~0.8x whatever 084 leaves it at.

## Design

Editorial-only: move and point, never rephrase a rule while moving it. For
each invariant, the AGENTS.md section that already exists (Review Records and
the Completion Gate; Layered Enforcement Model; Approved Plans Are Always
Committed; Completion Requires the Work Committed; The Health Gate Never
Silently No-Ops; Permission Not To Block...) is the canonical home — this
plan removes the full re-tellings elsewhere, it does not write new doctrine.
Where a SKILL needs the operational detail (exit code → action), keep the
table, drop the essay. New reference files:
`references/per-plan-agent-prompt.md`, `references/cross-plan-agent-prompt.md`,
`references/scoring-rubrics.md` under `skills/mstack-plan-doctor/` (dir
exists with 5 files). Grep-pin: the canonical sentences already in AGENTS.md
("ABSENT `review-required` ≠ empty required set", "A health gate that did not
run is not a health gate that passed", "anti-forgetfulness, not
anti-adversary") must survive verbatim in AGENTS.md and appear at most once
in full form repo-wide outside AGENTS.md.

Testing approach: unit-only.

**Files expected to change:**

- `AGENTS.md`: canonical statements confirmed/consolidated (mostly
  no-op — it is already the home).
- `skills/mstack-run/SKILL.md`: case-statement dedup, single tag war story,
  SKILL_DIR once, doctrine re-tellings → pointers.
- `skills/mstack-plan-doctor/SKILL.md`: prompts + rubrics extracted,
  SKILL_DIR once, doctrine re-tellings → pointers.
- `skills/mstack-plan-doctor/references/per-plan-agent-prompt.md`,
  `.../cross-plan-agent-prompt.md`, `.../scoring-rubrics.md`: NEW.
- `skills/mstack-run/references/review-spec.md`, `implement-spec.md`,
  `skills/mstack-status/SKILL.md`, `skills/mstack-backlog/SKILL.md`: trim
  full re-tellings to action + pointer where present.

**Out of scope:** any behavior change; renaming exit codes; touching
`references/CONVENTION.md` beyond the inventory (plan 071 owns that);
rewriting archived plans; changing what any script does.

## Tasks

1. Record post-084 baselines: `wc -l` both SKILL.md files; grep-inventory
   where each canonical sentence currently appears repo-wide.
2. Extract plan-doctor's two agent prompts and the Step 2 rubrics/auto-fixes
   to the three new reference files; leave composite formula + thresholds +
   Read-pointers inline.
3. Dedup mstack-run: exit-code case comments, tag war story, SKILL_DIR
   resolution; same SKILL_DIR pass in plan-doctor.
4. Convert full doctrine re-tellings in both SKILLs, review-spec/
   implement-spec, status and backlog into action + AGENTS.md pointer.
5. Re-run the grep-pins and all smoke suites; record final line counts
   against the reduction target.

## Verification

Checks:

- [assert] `grep -c 'ABSENT .review-required. ≠ empty required set' AGENTS.md` → >= 1
- [cmd] `grep -q 'anti-forgetfulness, not anti-adversary' AGENTS.md`
- [cmd] `grep -q 'not a health gate that passed' AGENTS.md`
- [assert] `grep -rl 'anti-forgetfulness, not anti-adversary' skills/ | wc -l` → <= 1 (the "at most once in full form outside AGENTS.md" pin; currently 1 — mstack-run/SKILL.md — must not grow)
- [assert] `grep -rl 'empty required set' skills/ | wc -l` → <= 1 (currently 2: mstack-run + plan-doctor SKILL.md both retell it; post-dedup at most one full telling survives outside AGENTS.md)
- [cmd] `test -f skills/mstack-plan-doctor/references/per-plan-agent-prompt.md`
- [cmd] `test -f skills/mstack-plan-doctor/references/scoring-rubrics.md`
- [assert] `grep -c 'SKILL_DIR=' skills/mstack-plan-doctor/SKILL.md` → <= 4
- [cmd] `awk 'END { exit (NR <= 1120) ? 0 : 1 }' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/health-reach-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/wrapup-scan-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/plan-ref-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
