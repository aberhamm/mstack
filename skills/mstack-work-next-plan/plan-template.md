<!--
Plan file template for the `mstack-work-next-plan` skill.
Copy this into `plans/NNN-slug.md` (NNN = zero-padded sequential id).

The skill picks the lowest-numbered plan with `status: pending` whose
`blocked-by` ids are all `status: done`. Frontmatter is the source of truth
for state — do not track plan status anywhere else.
-->

---
id: 001
title: Short imperative title (becomes branch name and PR title)
status: pending           # pending | in-progress | done | failed | blocked
blocked-by: []            # list of plan ids that must be `done` first, e.g. [042, 043]
allows-migrations: false  # true ONLY for plans that intentionally edit db/migrations/**
needs-review: none        # none | eng | design | ceo | eng,design | ceo,eng | ceo,design | ceo,eng,design — run the corresponding /plan-*-review skill(s) before mstack-work-next-plan picks it up
created: 2026-04-30
# Filled in by mstack-work-next-plan on completion:
# completed: <YYYY-MM-DD>
# reviewed: false         # false | true — has the human personally reviewed the shipped code
# qa: automated           # comma-separated: none | automated | e2e | browser
#                         #   automated = verification gate (typecheck/lint/unit tests)
#                         #   e2e = end-to-end integration tests
#                         #   browser = browser-based QA (scripted or manual)
# Filled in by mstack-work-next-plan on failure:
# failed-reason: <short>
# failed-at: <YYYY-MM-DD>
---

## Requirements

What user-visible problem does this solve? One paragraph. Be concrete: which
endpoint, which screen, which user. If you can't name a user, the plan is too
abstract to run unattended — break it down further.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle — be specific):

- [ ] ...
- [ ] ...
- [ ] ...

## Design

How will it work? Files expected to change. Schemas, types, contracts. Edge
cases the agent must handle. Anything that requires judgment goes here, not
in Tasks — Tasks is for execution, Design is for decisions.

**Files expected to change:**

- `path/to/file.ts` — what changes
- `path/to/other.ts` — what changes

**Out of scope:** name anything a sloppy agent might be tempted to also fix
but shouldn't.

## Tasks

Concrete, ordered execution steps. Each should be small enough to verify.

1. ...
2. ...
3. ...

## Verification

Tests to write or commands to run beyond the default gate
(`typecheck && lint && test`). Optional — leave blank if defaults suffice.

- ...
