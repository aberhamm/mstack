---
id: 035
title: Review skills record verdicts; forbid agents self-clearing gates
status: in-progress
blocked-by: [034]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
---

## Requirements

The gate from plan 034 trusts a *review record*, not a hand-edited
`needs-review: none`. For that to hold, two things must be true:

1. The review skills must actually **produce** those records when they run.
2. Every non-review actor (implementing/worker agents, `mstack-run` itself) must
   be **prohibited** from clearing a gate — no editing `needs-review` /
   `review-required` / `reviews` to clear, and no "proceeding outside the
   picker" to run a needs-review plan.

Only the corresponding review skill may clear a gate, by running and recording
its outcome: `plan-eng-review` / `plan-design-review` / `plan-ceo-review`
(orchestrated by `mstack-plan-doctor`) for eng/design/ceo, and
`mstack-code-review` for the code gate.

**Acceptance criteria:**

- [ ] `mstack-plan-doctor` Step 5 clearing path: when a reviewer approves, it
      calls `review-gate.sh record <plan> <type> approved` (in addition to any
      `needs-review` bookkeeping). On changes-requested it records
      `changes-requested` and does **not** clear.
- [ ] `mstack-code-review` records its verdict for type `code` via
      `review-gate.sh record`, using the fail condition defined in plan 034
      (unfixed critical/high finding remains → `fail`, else `pass`). A failing or
      absent code review leaves the code gate open.
- [ ] The worker/subagent prompt (`references/subagent-prompt.md`) and
      `references/implement-spec.md` contain an explicit prohibition scoped to
      *clearing or weakening* a gate: an implementing agent may not clear/remove
      `needs-review` tags, may not edit `review-required` or `reviews`, may not
      mark a needs-review plan done, and may not run a needs-review plan "outside
      the picker". **Adding or raising** a gate stays allowed — the worker is
      still instructed to add `needs-review: eng` when it hits an incomplete spec
      or stale seam (`subagent-prompt.md:31`, `SKILL.md:443/487`); do not break
      that path. The remediation for a needed clear is stated: run the named
      review skill.
- [ ] The exact observed anti-pattern is called out as forbidden with its fix
      (offering to self-clear `needs-review: eng` or to "say go and proceed
      outside the picker").
- [ ] `AGENTS.md` states the rule: only the named review skills write review
      records / clear gates.

## Design

Records are written exclusively through `review-gate.sh record`, invoked only
from the review skills. Keeping the write behind one CLI verb makes "who may
clear a gate" auditable — a grep for `review-gate.sh record` should only hit the
review skills.

`mstack-plan-doctor` currently clears by editing `needs-review` (SKILL.md
~:1067-1070). That stays for picker compatibility, but the *authoritative* clear
becomes the recorded verdict. So doctor: run review -> on approve, `record ...
approved` and drop the tag; on changes-requested, `record ...  changes-requested`
and leave tags as-is.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: Step 5 clearing path records verdicts.
- `skills/mstack-code-review/SKILL.md`: record the code verdict.
- `skills/mstack-run/references/subagent-prompt.md`,
  `skills/mstack-run/references/implement-spec.md`: prohibition clauses.
- `AGENTS.md`: the "only review skills clear gates" rule + the named
  anti-pattern.

**Out of scope:** the completion-path enforcement in `mstack-run` Step 7a and
the anti-downgrade wiring (plan 036). This plan makes records get *written* and
self-clearing get *forbidden in prose*; 036 makes the machine *refuse* to
complete when they're absent.

## Tasks

1. Wire `review-gate.sh record` into `mstack-plan-doctor` Step 5 (approve +
   changes-requested paths).
2. Wire `review-gate.sh record` into `mstack-code-review`'s verdict step.
3. Add prohibition clauses to the subagent prompt and implement-spec, naming the
   observed anti-pattern.
4. Add the "only review skills clear gates" rule to `AGENTS.md`.

## Verification

- `[cmd]` `bash -n` on any scripts touched; `shellcheck` clean.
- `[assert]` a scripted run of the doctor approve path produces a review record
  the gate reads as cleared (`review-gate.sh cleared <plan> eng` exits 0).
- `[assert]` a scripted changes-requested path leaves the gate open
  (`cleared ... eng` nonzero) and does not drop the tag.
- `[cmd]` grep confirms the prohibition text (self-clear / outside-the-picker) is
  present in the subagent prompt and implement-spec.
- `[cmd]` grep confirms `review-gate.sh record` is invoked only from the review
  skills (not from worker/implement paths).
- `[cmd]` inverse grep: no worker/implement path (`subagent-prompt.md`,
  `implement-spec.md`, `mstack-run` Step 4) instructs editing `needs-review`,
  `review-required`, or `reviews` to *clear/weaken* a gate. (Adding a
  `needs-review` tag is allowed and excluded from this assertion.)
