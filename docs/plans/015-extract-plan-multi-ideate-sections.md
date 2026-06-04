---
id: 15
title: Extract plan-multi and mstack-ideate reference sections
status: in-progress
blocked-by: [13]
allows-migrations: false
needs-review: none
created: 2026-06-04
---

## Requirements

plan-multi (504 lines) and mstack-ideate (409 lines) each contain large
conditional sections that only execute in specific code paths. plan-multi's
divergent decomposition (Step 3a, ~116 lines) only loads when the user
chooses "Explore" mode, and its structural critique (Step 3.5, ~108 lines)
could be deferred. mstack-ideate's post-scoring features (trap detection,
clustering, handoff) are sequential stages that can be loaded on demand.

This plan extracts these sections into `references/` subdirectories for
both skills, following the convention from plan 013.

**Acceptance criteria:**

- [ ] `skills/mstack-plan-multi/references/` exists with 2 reference files
- [ ] `skills/mstack-ideate/references/` exists with 3 reference files
- [ ] plan-multi's divergent decomposition (Step 3a, ~116 lines) is extracted to `references/divergent-decomposition.md` and loaded only when user chooses Explore mode
- [ ] plan-multi's structural critique (Step 3.5, ~108 lines) is extracted to `references/structural-critique.md` and loaded after decomposition
- [ ] mstack-ideate's critic pass with trap detection (~83 lines) is extracted to `references/critic-and-traps.md` and loaded at Step 4
- [ ] mstack-ideate's clustering step (~36 lines) is extracted to `references/clustering.md` and loaded at Step 5
- [ ] mstack-ideate's handoff section (~68 lines) is extracted to `references/handoff.md` and loaded at Step 7
- [ ] plan-multi main SKILL.md drops to ~290 lines or fewer (from 504)
- [ ] mstack-ideate main SKILL.md drops to ~220 lines or fewer (from 409)
- [ ] Read directives follow the convention from plan 013's CONVENTION.md
- [ ] Reference file paths use MSTACK_ROOT resolution for skillshare compatibility (mstack-ideate is resolved through MSTACK_ROOT, not a dedicated SKILL_DIR)
- [ ] No behavior changes in either skill

## Design

**Files expected to change:**

- `skills/mstack-plan-multi/SKILL.md` (MODIFY): replace extracted sections with Read directives
- `skills/mstack-plan-multi/references/divergent-decomposition.md` (NEW): Step 3a full flow (~156 lines)
- `skills/mstack-plan-multi/references/structural-critique.md` (NEW): Step 3.5 Codex + Sonnet critique (~108 lines)
- `skills/mstack-ideate/SKILL.md` (MODIFY): replace extracted sections with Read directives
- `skills/mstack-ideate/references/critic-and-traps.md` (NEW): Step 4 scoring + trap detection (~83 lines)
- `skills/mstack-ideate/references/clustering.md` (NEW): Step 5 approach-angle clustering (~36 lines)
- `skills/mstack-ideate/references/handoff.md` (NEW): Step 7 structured handoff to plan-multi (~68 lines)

**Approach:**

Follow the convention from plan 013's `references/CONVENTION.md`.

**plan-multi** retains inline:
- Frontmatter, philosophy, Step 1 (understand goal), Step 2 (research codebase)
- Step 3.0 (choose decomposition mode) -- the AskUserQuestion routing
- Step 3b (Direct mode single-pass decomposition) -- this is the default path
- Step 4 (present breakdown), Step 5 (write plan files), Step 6 (summary)

Divergent decomposition (Step 3a) only loads when user picks Explore. The
structural critique (Step 3.5) loads after decomposition regardless of mode
but is self-contained reference material.

**mstack-ideate** retains inline:
- Frontmatter, auto-init, Step 1 (input parsing)
- Step 2 (frame reading and selection)
- Step 3 (isolated branch generation)
- Step 6 (rank and present) -- the final output formatting

The critic pass, clustering, and handoff are sequential post-generation
stages. Each is self-contained and loads when its step is reached.

Note: mstack-ideate resolves paths through `$MSTACK_ROOT/skills/mstack-ideate/`
(same as cognitive-frames.md), not through a dedicated SKILL_DIR. Reference
file Read directives must use this resolution pattern.

Testing approach: unit-only

**Out of scope:**

- Changing any behavior in either skill
- Modifying plan-doctor or mstack-run references
- Changing the cognitive frames file

## Tasks

1. Read plan 013's `references/CONVENTION.md` to follow the established convention
2. Create `skills/mstack-plan-multi/references/` directory
3. Extract Step 3a divergent decomposition to `references/divergent-decomposition.md`, replace in SKILL.md with Read directive gated on Explore mode
4. Extract Step 3.5 structural critique to `references/structural-critique.md`, replace with Read directive
5. Create `skills/mstack-ideate/references/` directory
6. Extract Step 4 critic pass with trap detection to `references/critic-and-traps.md`, replace with Read directive
7. Extract Step 5 clustering to `references/clustering.md`, replace with Read directive
8. Extract Step 7 handoff to `references/handoff.md`, replace with Read directive
9. Verify both SKILL.md files meet line count targets

## Verification

- [cmd] test -d skills/mstack-plan-multi/references
- [cmd] test -d skills/mstack-ideate/references
- [assert] ls skills/mstack-plan-multi/references/*.md | wc -l | grep -E '^2$' (2 reference files)
- [assert] ls skills/mstack-ideate/references/*.md | wc -l | grep -E '^3$' (3 reference files)
- [assert] wc -l < skills/mstack-plan-multi/SKILL.md | awk '{print ($1 < 320) ? "PASS" : "FAIL"}' | grep PASS
- [assert] wc -l < skills/mstack-ideate/SKILL.md | awk '{print ($1 < 260) ? "PASS" : "FAIL"}' | grep PASS
- [assert] grep -c 'references/' skills/mstack-plan-multi/SKILL.md | grep -E '^[2-9]' (2+ Read directives)
- [assert] grep -c 'references/' skills/mstack-ideate/SKILL.md | grep -E '^[3-9]' (3+ Read directives)
