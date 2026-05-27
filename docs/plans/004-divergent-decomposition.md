---
id: 4
title: Add divergent decomposition to plan-backlog
status: pending
blocked-by: [1]
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

Plan-backlog currently converges on the first plausible decomposition when breaking down
a goal into plans. This means the architect always gets one perspective on how to
structure the work — missing potentially better architectures that a different framing
would reveal.

This plan adds divergent decomposition to plan-backlog's Step 3: generate 3 independent
candidate decompositions under different architectural frames, score them, and present
the best one with notable alternatives. This is opt-in via a new AskUserQuestion at the
start of Step 3 — the user chooses "Explore" (divergent) or "Direct" (single-pass).

**Acceptance criteria:**

- [ ] Plan-backlog Step 3 starts with an AskUserQuestion: "Explore" (divergent, 3 candidates) or "Direct" (single-pass, current behavior)
- [ ] Each candidate uses a different architectural frame from the shared cognitive frames library: "minimize coupling", "maximize parallelism", "simplest-thing-that-works" (or closest frames)
- [ ] Candidates are generated independently — no cross-talk between decomposition attempts
- [ ] A critic step scores each candidate on 4 axes: dependency depth, parallelism potential, scope-fit per plan, risk distribution
- [ ] A reconciliation step validates the winning decomposition: no circular deps, no scope gaps, no conflicting assumptions
- [ ] The user sees the winning decomposition in the standard table format plus a "Notable alternatives" section showing key differences from other candidates
- [ ] When the user chooses "Direct", the existing single-pass decomposition is used (no performance cost, identical to current behavior)
- [ ] The skill reads frame definitions from `skills/mstack-shared/cognitive-frames.md`

## Design

This modifies plan-backlog's Step 3 (Design the plan breakdown) to optionally run
a divergent-then-converge process. The modification is entirely within plan-backlog's
SKILL.md.

**Files expected to change:**

- `skills/mstack-plan-backlog/SKILL.md` — modify Step 3 to add divergent decomposition for Expand/Selective postures, add posture detection, add critic and reconciliation steps

**Approach:**

**Posture detection:** Plan-backlog doesn't currently have posture selection. Add an
AskUserQuestion at the start of Step 3 (after codebase research, before decomposition):

```
How should I approach this decomposition?

A) Explore — Generate 3 competing decompositions from different angles, pick the best
B) Direct — Single-pass decomposition (faster, good when the structure is obvious)
```

Map: Explore → divergent mode, Direct → existing single-pass mode.

**Divergent decomposition flow (Explore mode):**

1. Read 3 architectural frames from the cognitive frames library using the deterministic selection rules defined in `skills/mstack-shared/cognitive-frames.md` (do not re-specify selection logic here — reference the shared rules)
2. For each frame, generate a complete plan breakdown independently:
   - Same quality bar as existing Step 3 (plan list, execution order, review assignments)
   - Each decomposition is self-contained with its own DAG
3. **Critic step:** Score each candidate on:
   - Dependency depth (shallower = more parallelizable = better)
   - Parallelism potential (more plans that can run concurrently = better)
   - Scope-fit per plan (each plan is 1-3 hours of focused work)
   - Risk distribution (critical decisions spread across fewer plans = riskier)
4. **Reconciliation:** Take the highest-scoring candidate and validate:
   - No circular dependencies
   - No scope gaps (acceptance criteria from the goal are covered)
   - No conflicting assumptions between plans
   - Stable plan ordering (reorder if critic scoring suggests better sequencing)
5. **Present to user:** Standard table (Step 4) for the winner, plus:

```
Notable alternatives (from other decompositions):
  - Candidate B proposed splitting the auth plan into "schema" + "middleware" — 
    this increases parallelism but adds a dependency edge
  - Candidate C proposed a single monolithic plan for the API layer — 
    simpler but blocks all downstream work on one plan
```

**Cost/latency note:** Divergent mode generates 3x the decomposition tokens. This is
appropriate for Explore mode where the architect is investing time upfront. For Direct
mode, there is zero overhead — identical to current behavior.

**Out of scope:**

- Frame definitions (plan 001)
- Plan-doctor changes (plans 002, 003)
- mstack-ideate (plans 005, 006)
- Automatic posture detection (user always chooses)

## Tasks

1. Add posture selection AskUserQuestion to the start of Step 3 in plan-backlog SKILL.md
2. Add instruction to read `skills/mstack-shared/cognitive-frames.md` for frame definitions
3. Write the divergent decomposition flow: 3 independent candidates under different frames
4. Write the critic scoring step with the 4 evaluation axes
5. Write the reconciliation validation step (cycle detection, gap detection, assumption conflicts)
6. Add the "Notable alternatives" output section to Step 4 presentation
7. Ensure Direct mode preserves identical behavior to current Step 3 (no regression)

## Verification

- [assert] grep 'Explore' skills/mstack-plan-backlog/SKILL.md
- [assert] grep 'Direct' skills/mstack-plan-backlog/SKILL.md
- [assert] grep 'cognitive-frames.md' skills/mstack-plan-backlog/SKILL.md
- [assert] grep -i 'notable alternative' skills/mstack-plan-backlog/SKILL.md
- [assert] grep -i 'reconciliation' skills/mstack-plan-backlog/SKILL.md
- [assert] grep -i 'dependency depth\|parallelism\|risk distribution' skills/mstack-plan-backlog/SKILL.md
- [assert] grep -A5 'Direct' skills/mstack-plan-backlog/SKILL.md | grep -i 'existing\|single-pass\|current\|unchanged'

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **VERDICT:** ENG CLEARED — ready to implement
