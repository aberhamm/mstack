---
id: 5
title: Add mstack-ideate skill — scaffold and core ideation
status: pending
blocked-by: [1]
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

Before committing to plans, the architect sometimes needs to explore the problem space —
brainstorm approaches, consider alternatives, and surface non-obvious ideas. Currently
there's no mstack skill for this; the architect either thinks it through themselves or
jumps straight to plan-multi.

This plan creates the `/mstack-ideate` skill with the core ideation engine: take a
problem statement, run 3-5 isolated reasoning branches under different cognitive frames,
and produce ranked ideas with implementation sketches. The scoring/trap/handoff layer
comes in plan 006.

**Acceptance criteria:**

- [ ] A new skill file exists at `skills/mstack-ideate/SKILL.md`
- [ ] The skill accepts a problem statement or feature idea as input
- [ ] It generates 3-5 independent ideation branches, each using a different cognitive frame from the shared library
- [ ] Branches are isolated — no cross-contamination between reasoning paths
- [ ] Each branch produces 2-4 concrete ideas with: title, one-paragraph description, key tradeoff, and a 3-5 sentence implementation sketch
- [ ] A critic pass evaluates all ideas across branches on 3 axes: novelty (0-10), viability (0-10), fit (0-10)
- [ ] Ideas are ranked by weighted score: viability 0.4, novelty 0.35, fit 0.25
- [ ] Output includes: ranked list with scores, a "non-obvious pick" highlight (highest novelty among viable ideas), and a "provocation" (the wildest idea reframed as "What if we took this seriously?")
- [ ] The skill has appropriate triggers and routing rules
- [ ] Frame selection uses the deterministic rules from the shared library, choosing frames based on the problem domain

## Design

New skill file, self-contained. Reads cognitive frames from the shared library.

**Files expected to change:**

- `skills/mstack-ideate/SKILL.md` — NEW: the ideation skill
- `README.md` — add mstack-ideate to the Skills table

**Approach:**

**Skill structure:**

```
---
name: mstack-ideate
description: |
  Divergent idea exploration before committing to plans. Multiple isolated
  reasoning branches under different cognitive frames, scored and ranked.
  Output feeds into /mstack-plan-multi.
argument-hint: "<problem statement or feature idea>"
triggers:
  - brainstorm
  - explore ideas
  - what could we build
  - ideate
  - think through
  - idea generation
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---
```

**Core ideation flow:**

1. **Parse input** — extract the problem statement
2. **Read frames** — load `skills/mstack-shared/cognitive-frames.md`, select 3-5 frames based on problem keywords (more frames for broader problems, fewer for focused ones)
3. **Generate branches** — for each selected frame, produce ideas through that frame's lens:
   - System prompt: the frame's prompt fragment + "You are a generator, not a critic. Do not evaluate, hedge, or rank. Produce concrete ideas."
   - Each branch outputs 2-4 ideas in structured format
4. **Critic pass** — separate evaluation step with opposing prompt: "You are a skeptical evaluator. Score each idea honestly. Flag ideas that look good but won't survive contact with reality."
   - Score each idea: novelty (0-10), viability (0-10), fit (0-10)
   - Weighted total: viability 0.4, novelty 0.35, fit 0.25
5. **Rank and present:**

```
IDEATION RESULTS — "How should we handle auth for the API?"
═══════════════════════════════════════════════════════════════

Ranked ideas:
  1. [8.2] JWT with refresh rotation (via Security Auditor)
     Stateless auth with short-lived access tokens and rotating refresh tokens.
     Tradeoff: more complex token management vs. no server-side session state.
     Sketch: Add jwt middleware, create /auth/token and /auth/refresh endpoints,
     store refresh token family in DB for rotation tracking, add token blacklist
     for logout.

  2. [7.8] Session-based with Redis (via Performance Engineer)
     ...

  3. [7.1] API key + webhook signatures (via Simplicity Advocate)
     ...

⭐ Non-obvious pick: #3 — API key + webhook signatures
   Highest novelty among viable options. Worth considering if the API
   is primarily machine-to-machine.

💡 Provocation: "What if we took API keys seriously?"
   Instead of treating API keys as the simple fallback, what if the entire
   auth system was key-based with scoped permissions, rate limiting per key,
   and automatic key rotation? No passwords, no sessions, no tokens.
```

**Generator/critic separation:** The generator prompt explicitly says "do not evaluate."
The critic prompt explicitly says "do not generate new ideas." This structural separation
prevents premature convergence — the same insight from the ADHD framework that inspired
this feature.

**Out of scope:**

- Trap detection on ideas (plan 006)
- Clustering by angle (plan 006)
- Handoff to plan-multi (plan 006)
- Integration with plan-doctor or plan-multi

## Tasks

1. Create `skills/mstack-ideate/` directory
2. Write `SKILL.md` with frontmatter (name, description, triggers, allowed-tools)
3. Implement Step 1: input parsing and problem statement extraction
4. Implement Step 2: frame reading and deterministic selection
5. Implement Step 3: isolated branch generation with generator-only prompt
6. Implement Step 4: critic pass with opposing evaluator prompt and scoring
7. Implement Step 5: ranking, non-obvious pick selection, and provocation generation
8. Add mstack-ideate to README.md Skills table

## Verification

- [cmd] test -f skills/mstack-ideate/SKILL.md
- [assert] grep 'mstack-ideate' skills/mstack-ideate/SKILL.md
- [assert] grep 'cognitive-frames.md' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'generator.*not.*critic\|not.*evaluate\|not.*rank' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'novelty.*viability.*fit\|viability.*novelty.*fit' skills/mstack-ideate/SKILL.md
- [assert] grep -i 'non-obvious\|provocation' skills/mstack-ideate/SKILL.md
- [assert] grep 'mstack-ideate' README.md

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **VERDICT:** ENG CLEARED — ready to implement
