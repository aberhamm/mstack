---
id: 3
title: Add trap resistance scoring to plan-doctor
status: pending
blocked-by: [2]
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

Plans can contain patterns that look attractive during review but hide costs at
implementation time: premature abstractions, false economies, won't-scale approaches,
hidden coupling, and scope creep magnets. The existing 4 scoring dimensions don't
explicitly surface these — a plan can score 8/10 on all dimensions while containing
a pattern that will fail at scale.

This plan adds a 5th scoring dimension: "Trap resistance (0-10)" where higher is safer
(consistent with existing dimensions — higher is always better). The trap detector
uses a deliberately adversarial evaluation prompt that opposes the plan author's
optimistic framing.

**Acceptance criteria:**

- [ ] Plan-doctor Step 2 scores a 5th dimension: "Trap resistance" (0-10, higher = safer)
- [ ] Trap resistance has a strict definition that does NOT overlap with existing dimensions: it evaluates whether the plan's approach contains patterns that are seductively simple but will fail under real-world conditions
- [ ] The trap detector prompt uses an opposing stance: "Assume this plan's approach will fail. Find the patterns that look good on paper but will break in practice."
- [ ] Specific trap categories are defined: premature abstraction, false economy, hidden coupling, won't-scale pattern, scope creep magnet
- [ ] Each detected trap is named, categorized, and gets a one-line mitigation suggestion
- [ ] Plans scoring below 6/10 on trap resistance get an explicit warning with the specific trap identified
- [ ] Plans scoring below 4/10 trigger auto-fix: the trap detector suggests a Design section edit to mitigate the trap
- [ ] Trap resistance integrates into the composite score (suggested weight: 10%, configurable via .mstack/config.json)
- [ ] The composite score formula is documented in the SKILL.md

## Design

This extends plan-doctor's Step 2 scoring with a 5th dimension. The implementation is
entirely within plan-doctor's SKILL.md.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md` — add trap resistance dimension to Step 2, update composite formula, add trap-specific auto-fix logic, update report format

**Approach:**

**Strict boundary vs existing dimensions:**
- Clarity: "Can someone understand what to build?" — about communication
- Testability: "Can we prove it worked?" — about verification
- Scope-fit: "Is this the right size?" — about granularity
- Autonomy-readiness: "Can the worker implement without asking?" — about completeness
- **Trap resistance: "Will this approach actually work under real conditions?"** — about hidden failure modes in the chosen approach itself, not its description

The key distinction: a plan can be perfectly clear, testable, well-scoped, and
autonomy-ready while still choosing an approach that will fail at scale. Trap
resistance catches the approach-level risk that the other dimensions don't evaluate.

**Trap categories (each with detection heuristic):**

1. **Premature abstraction** — Plan introduces a generic framework/abstraction when a direct implementation would suffice. Heuristic: plan mentions "reusable", "extensible", "generic" for a first implementation.
2. **False economy** — Plan takes a shortcut that creates more work downstream. Heuristic: plan skips a step "for now" or defers a concern that blocked-by plans will need.
3. **Hidden coupling** — Plan's approach creates implicit dependencies not captured in blocked-by. Heuristic: plan modifies shared state, globals, or files also listed in other plans without dependency.
4. **Won't-scale pattern** — Approach works for current data size but has O(n²) or worse characteristics. Heuristic: plan uses in-memory processing, nested loops, or synchronous calls for data that could grow.
5. **Scope creep magnet** — Plan's design is broad enough that the worker will be tempted to expand scope. Heuristic: "Out of scope" section is missing or thin relative to the plan's breadth.

**Scoring rubric:**
- 10: No traps detected. Approach is direct and proportionate.
- 7-9: Minor trap risk. One advisory-level pattern that probably won't bite.
- 4-6: Moderate trap risk. One or more patterns that could cause rework.
- 1-3: High trap risk. Approach is likely to fail or create significant downstream cost.

**Auto-fix (below 4/10):**
Same pattern as existing autonomy auto-fix: read the codebase, infer a safer approach,
edit the plan's Design section. Log the change.

**Composite score update:**
Current: implicit equal weighting across 4 dimensions (no formula documented).
New: explicit weights for all 5 dimensions — clarity 20%, testability 25%, scope-fit 20%, autonomy-readiness 25%, trap resistance 10%. This is the first time composite weights are made explicit — the worker should add the full formula for all 5 dimensions, not just the trap resistance weight. Document the formula in a new `### Composite score formula` subsection within Step 2.

The weights are hardcoded in the SKILL.md prose. Document that `.mstack/config.json` key `health.weights.planning` can override them, and add the key to the config documentation within the SKILL.md (not to config.json itself — `config.sh` reads arbitrary keys).

**Out of scope:**

- Frame-based review (plan 002)
- Changes to plan-multi or mstack-ideate
- Changes to `config.sh` or any scripts (the config key is documented in SKILL.md only; `config.sh get` already reads arbitrary keys)

## Tasks

1. Add the trap resistance dimension definition to Step 2 in plan-doctor SKILL.md (strict boundary, rubric, categories)
2. Write the opposing-stance detector prompt instructions
3. Define the 5 trap categories with detection heuristics
4. Add scoring output: trap findings with category, name, and mitigation
5. Add auto-fix logic for plans scoring below 4/10 on trap resistance
6. Update the composite score formula with explicit weights for all 5 dimensions
7. Document the configurable weight under `.mstack/config.json` → `health.weights.planning`
8. Update the Step 4 report, Step 6 summary, and "what would make it a 10" section to include trap resistance

## Verification

- [assert] grep -i 'trap resistance' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -i 'premature abstraction' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -i 'false economy' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -i 'hidden coupling' skills/mstack-plan-doctor/SKILL.md
- [assert] grep 'health.weights.planning' skills/mstack-plan-doctor/SKILL.md
- [assert] grep -c 'trap' skills/mstack-plan-doctor/SKILL.md | grep -E '^[5-9]|^[1-9][0-9]'
- [assert] grep 'Composite.*formula\|composite.*weight\|clarity.*20.*testability.*25' skills/mstack-plan-doctor/SKILL.md

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **VERDICT:** ENG CLEARED — ready to implement
