---
id: 1
title: Add shared cognitive frames reference
status: pending
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

mstack's planning pipeline currently reviews plans from a single perspective. When
plan-doctor validates a plan, it scores clarity/testability/scope-fit/autonomy-readiness
but always through the same lens. This misses blind spots that a security auditor,
performance engineer, or end user would catch immediately.

This plan creates a shared cognitive frames library that plan-doctor, plan-multi, and
future skills (mstack-ideate) can reference. Frames are reusable prompt blocks: each
defines a distinct perspective with its own vocabulary, biases, and what it uniquely sees.

**Acceptance criteria:**

- [ ] A new file `skills/mstack-shared/cognitive-frames.md` exists with 8-10 frame definitions
- [ ] Each frame has: name, review checklist (specific items to check), behavioral bias (how to think, not who to be), what it catches that others miss, and 2-3 example findings
- [ ] System prompt fragments use behavioral instructions ("Check for X, flag Y, assume Z"), never identity claims ("You are an expert X"). Per USC research (arXiv:2603.18507): persona prompting degrades accuracy on knowledge tasks; behavior-first instructions preserve accuracy while still shaping review focus
- [ ] Frame selection rules are deterministic, based on plan characteristics (files touched, keywords, domain), not random
- [ ] Selection logic documented: given a plan's metadata, how are 3 frames chosen?
- [ ] Frames cover these perspectives at minimum: security auditor, performance/scaling engineer, 3am-on-call SRE, end user/product thinker, adversarial tester, cost/budget analyst, simplicity advocate, future maintainer
- [ ] The file is self-contained markdown (no TypeScript, no imports, no runtime dependencies)

## Design

Create a new shared reference directory and file that other skills can include by reading.

**Files expected to change:**

- `skills/mstack-shared/cognitive-frames.md` (NEW): the frame library
- `README.md`: add cognitive frames to the Skills table as a supporting reference

**Approach:**

Each frame is a markdown section with structured fields. Frame design follows
behavior-first prompting (per USC research arXiv:2603.18507; persona identity
claims degrade accuracy; behavioral instructions preserve it):

```markdown
### Security Review

**Review checklist:**
- Unvalidated inputs and missing sanitization
- Missing auth checks on new endpoints
- Data exposure risks and trust boundary violations
- Injection vectors (SQL, command, prompt)
- Privilege escalation paths

**Behavioral bias:** Assume every input is hostile. Assume attackers will find
every shortcut. Flag anything that handles user data without explicit sanitization.

**What this catches that other frames miss:** Trust boundaries and data flow
risks that functional reviewers overlook.

**Keywords:** auth, security, tokens, passwords, uploads, user data, API, endpoints

**Example findings:**
- "Plan creates a new API endpoint but doesn't specify auth middleware"
- "File upload handler doesn't mention size limits or type validation"
```

**Why behavior-first, not persona-first:** Research shows "you are an expert X"
prompting activates style-matching mode which competes with factual retrieval.
Frames should specify what to check and how to think, not who to be. The frame
name (e.g., "Security Review") serves as a human-readable label only; the system
prompt fragment never says "you are a security auditor."

**Frame selection rules (deterministic):**

1. **Mandatory frame:** Always include "Simplicity Advocate" (catches over-engineering)
2. **Domain match:** If plan touches `auth/`, `security/`, or mentions tokens/passwords → include Security Auditor. If plan touches `db/`, `migrations/`, or performance-sensitive paths → include Performance Engineer. If plan touches user-facing files → include End User.
3. **Fill remaining:** From unselected frames, pick by plan keyword matching (each frame has associated keywords). Tiebreak by frame index (stable ordering).

Total: always exactly 3 frames per plan review.

**Out of scope:**

- Wiring frames into plan-doctor (plan 002)
- Wiring frames into plan-multi (plan 004)
- Any runtime code or scripts

## Tasks

1. Create `skills/mstack-shared/` directory
2. Write `cognitive-frames.md` with all 8-10 frame definitions following the structured format above
3. Write the deterministic selection algorithm as a prose specification within the file (a "## Selection Rules" section)
4. Add the mstack-shared directory to the Skills table in README.md as a supporting reference
5. Verify all frames have complete fields (persona, prompt fragment, bias, examples)

## Verification

- [cmd] test -f skills/mstack-shared/cognitive-frames.md
- [assert] grep -c '### ' skills/mstack-shared/cognitive-frames.md | grep -E '^[89]$|^10$' (8-10 frame headings)
- [assert] grep -c 'Review checklist' skills/mstack-shared/cognitive-frames.md | grep -E '^[89]$|^10$' (each frame has a checklist)
- [assert] grep -c 'Behavioral bias' skills/mstack-shared/cognitive-frames.md | grep -E '^[89]$|^10$' (each frame has behavioral instructions)
- [assert] grep '## Selection Rules' skills/mstack-shared/cognitive-frames.md
- [assert] grep 'mstack-shared' README.md

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | -- | -- |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | -- | -- |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | -- | -- |

- **VERDICT:** ENG CLEARED. Ready to implement.
