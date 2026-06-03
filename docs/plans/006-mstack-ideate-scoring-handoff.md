---
id: 6
title: Add mstack-ideate scoring refinement, trap detection, and backlog handoff
status: done
completed: 2026-06-03
reviewed: false
qa: automated,verified
blocked-by: [3, 5]
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

The core ideation engine (plan 005) produces ranked ideas but lacks trap detection,
clustering, and a clean handoff path to plan-multi. This plan adds the refinement
layer that makes ideation output actionable.

**Acceptance criteria:**

- [ ] Trap detection integrated into the critic pass: ideas that look attractive but hide costs are flagged with the trap category and a one-line reason (duplicate the 5 trap category definitions from plan 003 inline: premature abstraction, false economy, hidden coupling, won't-scale pattern, scope creep magnet)
- [ ] Ideas are clustered by "underlying angle," meaning groups of ideas that approach the problem from the same direction, even if surface-level different
- [ ] Cluster output shows which frames produced similar ideas (convergence signal = higher confidence)
- [ ] The ideation output ends with a structured "Handoff" section: a ready-to-paste `/mstack-plan-multi` argument for each of the top 3 ideas
- [ ] Handoff format includes: the chosen idea title, a one-paragraph goal description, and any constraints/decisions from the ideation that should carry forward
- [ ] The user can select which idea(s) to hand off via AskUserQuestion
- [ ] Routing rules documented in the skill's SKILL.md triggers list: "brainstorm", "explore ideas", "ideate". Note: the user's global CLAUDE.md routing is the user's responsibility to update; the skill only needs correct triggers in its frontmatter
- [ ] Skill triggers updated to cover natural language variations

## Design

This extends the mstack-ideate skill from plan 005 with additional refinement steps
after the core critic pass.

**Files expected to change:**

- `skills/mstack-ideate/SKILL.md`: add trap detection to critic, add clustering step, add handoff section with user selection
- `README.md`: update mstack-ideate description to mention trap detection and backlog handoff

**Approach:**

**Trap detection in critic pass:**

After scoring novelty/viability/fit, the critic also evaluates each idea for traps:

```
For each idea, check: does this approach contain a trap?
Trap categories: premature abstraction, false economy, hidden coupling,
won't-scale pattern, scope creep magnet.

If a trap is detected, flag it:
  ⚠️ TRAP [false economy]: "Using SQLite seems simpler but will require
  a migration to Postgres within 3 months at projected load."
```

Trap-flagged ideas keep their score but get a visible warning. The user decides
whether the trap is acceptable or disqualifying.

**Clustering step (after scoring, before presentation):**

Group ideas by underlying approach angle. Two ideas from different frames that
both propose "event-driven architecture" are in the same cluster. Clustering
prompt:

```
Group these ideas by their underlying approach, not by surface-level features
or the frame that generated them, but by the fundamental architectural bet
they're making. Name each cluster with a 3-5 word label.
```

Output:

```
Clusters:
  "Stateful server-side": ideas #1, #4 (from Security Auditor, SRE)
  "Stateless token-based": ideas #2, #5 (from Performance Engineer, Simplicity Advocate)
  "External delegation": idea #3 (from Cost Analyst)

Convergence signal: 2 frames independently proposed stateless approaches → higher confidence
```

**Handoff section:**

After the user reviews the ranked ideas, clustering, and traps:

```
Ready to plan? Select idea(s) to hand off to /mstack-plan-multi:

A) #1: JWT with refresh rotation
B) #2: Session-based with Redis
C) #3: API key + webhook signatures
D) Custom: combine elements from multiple ideas
```

For the selected idea(s), generate a handoff block:

```
HANDOFF → /mstack-plan-multi

Goal: Implement JWT authentication with refresh token rotation for the API.

The auth system uses short-lived access tokens (15min) with rotating refresh
tokens stored in the database. Includes /auth/token, /auth/refresh, and
/auth/revoke endpoints. Token blacklist for logout support.

Constraints from ideation:
- Must be stateless for horizontal scaling (from Performance Engineer frame)
- Refresh token rotation required; single-use tokens prevent replay (from Security Auditor frame)
- Trap warning: token blacklist adds server-side state; consider TTL-based expiry instead
```

The user can copy-paste this directly as a `/mstack-plan-multi` argument. Direct
programmatic invocation is not supported. The handoff prints the ready-to-paste
argument and tells the user to run `/mstack-plan-multi` with it. This avoids
needing `Skill` in allowed-tools and keeps the boundary between ideation and planning
explicit.

**Out of scope:**

- Core ideation engine changes (plan 005 handles generation and basic scoring)
- Plan-doctor changes (plans 002, 003)
- Plan-backlog changes (plan 004)

## Tasks

1. Add trap detection to the critic pass in mstack-ideate SKILL.md (duplicate the 5 trap categories inline: premature abstraction, false economy, hidden coupling, won't-scale pattern, scope creep magnet, same definitions as plan-doctor's SKILL.md)
2. Add the clustering step after scoring: group by underlying angle, surface convergence signals
3. Add the handoff section with AskUserQuestion for idea selection
4. Define the handoff output format: goal description + constraints + trap warnings
5. Format the handoff output as a ready-to-paste `/mstack-plan-multi` argument (no direct invocation; print the argument for the user to run)
6. Update triggers list in the skill's frontmatter to cover natural language variations
7. Update README.md description for mstack-ideate

## Verification

- [assert] grep -i 'trap.*false economy\|trap.*premature\|trap.*coupling' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'cluster' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'convergence' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'handoff\|hand off' skills/mstack-ideate/SKILL.md
- [assert] grep 'mstack-plan-multi' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'AskUserQuestion' skills/mstack-ideate/SKILL.md

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | -- | -- |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | -- | -- |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | -- | -- |

- **VERDICT:** ENG CLEARED. Ready to implement.
