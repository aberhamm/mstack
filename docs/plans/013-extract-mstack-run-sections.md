---
id: 13
title: Extract mstack-run reference sections for progressive disclosure
status: pending
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-06-04
---

## Requirements

mstack-run's SKILL.md is 1,244 lines loaded in full on every invocation. Most
of that content is the subagent reference specification (Steps 4-6) which the
parent agent never executes directly, plus conditional features (progress
output, cleanup sweep, final validation) that only run in specific code paths.
This wastes context window on content the agent does not need for the current
step.

This plan extracts additive sections into `skills/mstack-run/references/`
sub-files loaded on demand via explicit Read directives. It also establishes
the convention for all subsequent extraction plans (014, 015).

**Acceptance criteria:**

- [ ] A `skills/mstack-run/references/` directory exists with 5-7 markdown files
- [ ] The subagent prompt template (Step 3d) is extracted to `references/subagent-prompt.md` and loaded via an explicit Read directive when Step 3d executes
- [ ] Steps 4-6 reference specification (implement, health gate, verification gate, cleanup sweep, code review) is extracted to individual reference files, with a note in SKILL.md that these are authoritative specs maintained in references/
- [ ] Progress output format is extracted to `references/progress-format.md` and loaded at Step 2
- [ ] Final validation logic is extracted to `references/final-validation.md` and loaded at Step 8
- [ ] The main SKILL.md drops to ~600 lines or fewer (from 1,244)
- [ ] A `references/CONVENTION.md` file documents the progressive disclosure convention: file naming, Read directive format, fallback behavior, when to extract vs. keep inline
- [ ] All Read directives use the pattern: `> **Read** references/<file>.md before proceeding.` (deterministic, not judgment-based)
- [ ] No behavior changes: the skill produces identical results before and after refactoring
- [ ] Reference file paths use the MSTACK_ROOT resolution pattern so they work in repos where mstack is installed via skillshare

## Design

**Files expected to change:**

- `skills/mstack-run/SKILL.md` (MODIFY): replace extracted sections with Read directives, keep the routing/orchestration logic inline
- `skills/mstack-run/references/CONVENTION.md` (NEW): progressive disclosure convention spec
- `skills/mstack-run/references/subagent-prompt.md` (NEW): Step 3d prompt template (~183 lines)
- `skills/mstack-run/references/implement-spec.md` (NEW): Step 4 reference (~58 lines)
- `skills/mstack-run/references/health-gate-spec.md` (NEW): Step 5 reference (~61 lines)
- `skills/mstack-run/references/verification-spec.md` (NEW): Step 5b reference (~133 lines)
- `skills/mstack-run/references/cleanup-spec.md` (NEW): Step 5c reference (~68 lines)
- `skills/mstack-run/references/review-spec.md` (NEW): Step 6 reference (~54 lines)
- `skills/mstack-run/references/progress-format.md` (NEW): progress output format (~33 lines)
- `skills/mstack-run/references/final-validation.md` (NEW): final validation logic (~50 lines)

**Approach:**

The convention follows the Anthropic-documented `references/` pattern for
skill sub-files, proven in production by the gstack `ship` skill (which uses
the same explicit-Read-directive approach with 8 section files).

Each extracted section becomes a self-contained reference file. The main
SKILL.md retains:
- Frontmatter and preamble
- Hard rules
- Step 1 (startup, bail checks, config, checkpoint)
- Step 1b (scoped execution parsing)
- Step 2 (pick next plan)
- Step 3 (snapshot, readiness gate, learnings, stash check)
- Step 3d skeleton (delegate to subagent -- but reads the prompt template from references/)
- Step 7 (commit outcome -- routing logic only, not the subagent specs)
- Step 7c-7e (learnings, checkpoint, worktree cleanup)
- Step 8 skeleton (signal completion -- reads final validation from references/)
- Recovery section

The key insight: Steps 4-6 are labeled "the detailed reference for the
subagent's behavior" in the current SKILL.md. They already exist as a
redundant authoritative copy alongside the condensed version in Step 3d's
prompt template. Extracting them to references/ makes this relationship
explicit without changing any behavior.

**CONVENTION.md contents:**

```
# Progressive Disclosure Convention

## When to extract
- Section is >50 lines AND only executes in one code path
- Section is a reference specification (not directly executed by the main agent)
- Section is conditionally loaded (only needed in Explore mode, only on goal runs, etc.)

## When to keep inline
- Section is <50 lines
- Section is the routing/decision logic (always executed)
- Section is hard rules or safety constraints (must always be visible)

## File naming
- references/<descriptive-slug>.md
- Use the step name or feature name, not step numbers (numbers change)

## Read directive format
> **Read** references/<file>.md before proceeding.

## Path resolution
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
Read "$SKILL_DIR/references/<file>.md"

## Fallback behavior
If a reference file is missing, log a warning and skip the step.
Reference-based steps are additive (frame review, trap detection, etc.),
not blocking. Core routing logic stays inline and never depends on
reference files existing.
```

Testing approach: unit-only

**Out of scope:**

- Extracting sections from plan-doctor (plan 014)
- Extracting sections from plan-multi or ideate (plan 015)
- Changing any skill behavior or output
- Modifying scripts/ directory or bash scripts

## Tasks

1. Create `skills/mstack-run/references/` directory
2. Write `references/CONVENTION.md` with the progressive disclosure convention spec
3. Extract Step 3d's subagent prompt template to `references/subagent-prompt.md`, replace in SKILL.md with a Read directive
4. Extract Steps 4-6 reference specifications to individual reference files (implement-spec, health-gate-spec, verification-spec, cleanup-spec, review-spec), replace in SKILL.md with a note pointing to references/
5. Extract progress output format to `references/progress-format.md`, add Read directive at Step 2
6. Extract final validation logic to `references/final-validation.md`, add Read directive at Step 8
7. Verify main SKILL.md is ~600 lines or fewer
8. Verify all Read directives use the MSTACK_ROOT resolution pattern

## Verification

- [cmd] test -d skills/mstack-run/references
- [cmd] test -f skills/mstack-run/references/CONVENTION.md
- [cmd] test -f skills/mstack-run/references/subagent-prompt.md
- [assert] ls skills/mstack-run/references/*.md | wc -l | grep -E '^[89]|^1[0-9]' (8-10 reference files)
- [assert] wc -l < skills/mstack-run/SKILL.md | awk '{print ($1 < 650) ? "PASS" : "FAIL"}' | grep PASS
- [assert] grep -c 'references/' skills/mstack-run/SKILL.md | grep -E '^[5-9]|^[1-9][0-9]' (5+ Read directives)
- [assert] grep 'CONVENTION' skills/mstack-run/references/CONVENTION.md
- [assert] grep 'MSTACK_ROOT\|SKILL_DIR' skills/mstack-run/references/CONVENTION.md
