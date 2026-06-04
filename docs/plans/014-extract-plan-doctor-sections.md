---
id: 14
title: Extract plan-doctor reference sections for progressive disclosure
status: done
completed: 2026-06-04
reviewed: false
qa: automated,verified
blocked-by: [13]
allows-migrations: false
needs-review: none
created: 2026-06-04
---

## Requirements

plan-doctor's SKILL.md is 1,119 lines loaded in full on every invocation.
Several large sections are additive features that only execute in specific
code paths: the testing infrastructure audit (Step 0b, only on first init),
the multi-frame review (Step 2c, only when cognitive frames file exists),
and the trap resistance scoring (embedded in Step 2, always scored but the
detailed category definitions and heuristics are reference material).

This plan extracts these sections into `skills/mstack-plan-doctor/references/`
following the convention established in plan 013.

**Acceptance criteria:**

- [ ] A `skills/mstack-plan-doctor/references/` directory exists with 3 reference files
- [ ] The testing infrastructure audit (Step 0b, ~92 lines) is extracted to `references/testing-audit.md` and loaded via Read directive when Step 0b executes
- [ ] The trap resistance scoring definitions and heuristics (~95 lines) are extracted to `references/trap-resistance.md` and loaded via Read directive when scoring trap resistance in Step 2
- [ ] The multi-frame review (Step 2c, ~129 lines) is extracted to `references/frame-review.md` and loaded via Read directive when Step 2c executes
- [ ] The main SKILL.md drops to ~820 lines or fewer (from 1,119)
- [ ] Read directives follow the convention from plan 013's CONVENTION.md
- [ ] No behavior changes: plan-doctor produces identical results before and after

## Design

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md` (MODIFY): replace extracted sections with Read directives
- `skills/mstack-plan-doctor/references/testing-audit.md` (NEW): Step 0b testing infrastructure audit (~92 lines)
- `skills/mstack-plan-doctor/references/trap-resistance.md` (NEW): trap categories, heuristics, rubric, auto-fix logic (~95 lines)
- `skills/mstack-plan-doctor/references/frame-review.md` (NEW): Step 2c multi-frame review with selection rules, finding format, scoring integration, auto-fix (~129 lines)

**Approach:**

Follow the convention from plan 013's `references/CONVENTION.md`. Each
extracted section is >50 lines and executes in a specific code path.

The main SKILL.md retains:
- Discovery, auto-init, posture selection
- Step 0 (status dashboard) -- small, always runs
- Step 0b skeleton with Read directive (the audit details move to references/)
- Step 1 (locate plans)
- Step 1b (choose review posture)
- Step 2 base scoring (clarity, testability, scope-fit, autonomy-readiness) -- these are the core dimensions, kept inline
- Step 2 trap resistance skeleton with Read directive (the category definitions and heuristics move to references/)
- Step 2 composite score formula -- small (~20 lines), kept inline
- Step 2b (learnings check) -- small, kept inline
- Step 2c skeleton with Read directive (the full frame review process moves to references/)
- Steps 3-6 (structural validation, report, reviews, summary) -- routing logic, kept inline

Testing approach: unit-only

**Out of scope:**

- Changing plan-doctor behavior or scoring
- Modifying the cognitive frames file
- Extracting sections from other skills

## Tasks

1. Read plan 013's `references/CONVENTION.md` to follow the established convention
2. Create `skills/mstack-plan-doctor/references/` directory
3. Extract Step 0b testing audit to `references/testing-audit.md`, replace in SKILL.md with Read directive
4. Extract trap resistance definitions to `references/trap-resistance.md`: gather from two non-contiguous locations (category definitions + heuristics in Step 2 scoring, AND the auto-fix trap resistance section ~170 lines below). Keep the dimension header and scoring rubric summary inline, add Read directive for the detailed content
5. Extract Step 2c multi-frame review to `references/frame-review.md`, replace in SKILL.md with Read directive
6. Verify main SKILL.md is ~820 lines or fewer

## Verification

- [cmd] test -d skills/mstack-plan-doctor/references
- [assert] ls skills/mstack-plan-doctor/references/*.md | wc -l | grep -E '^3$' (3 reference files)
- [assert] wc -l < skills/mstack-plan-doctor/SKILL.md | awk '{print ($1 < 850) ? "PASS" : "FAIL"}' | grep PASS
- [assert] grep -c 'references/' skills/mstack-plan-doctor/SKILL.md | grep -E '^[3-9]' (3+ Read directives)
- [cmd] test -f skills/mstack-plan-doctor/references/testing-audit.md
- [cmd] test -f skills/mstack-plan-doctor/references/trap-resistance.md
- [cmd] test -f skills/mstack-plan-doctor/references/frame-review.md
