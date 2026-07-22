---
id: 044
title: retire or relocate the learnings subsystem so durable knowledge is committed
status: pending
blocked-by: []
priority:
goal:
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-07-22
qa: manual
reviews: []
---

## Requirements

The mstack learnings subsystem writes durable project knowledge to
`.mstack/learnings.jsonl`, and `.mstack/` is **gitignored** (`.gitignore:6`). So
every "learning" the pipeline extracts is **uncommitted, per-machine, invisible
in review, and gone on a fresh clone**. Knowledge that belongs to the repository
lives in a store that the repository cannot see. This is the same
invisible-state failure class mstack already abolishes elsewhere (the review-gate
doctrine: a declaration under gitignored `.mstack/` "would be invisible to
review, per-checkout, and gone on a fresh clone").

The wrap-up router was the first place this bias surfaced, and it has already
been fixed (commit `74e04dc`): durable knowledge now routes to a **committed doc
via progressive disclosure**, with `mstack-learned-patterns`/host-memory demoted
to fallbacks. **This plan makes the rest of the pipeline consistent with that
decision** — today `mstack-run` still runs the learnings loop as a primary
mechanism, so the two halves of the system now disagree.

### The design fork this plan must resolve FIRST (it is not yet decided)

This plan is **not implementation-ready until the fork below is chosen** — that
choice is deliverable #1, and the eng review gate exists to ratify it before any
code moves. Do not start ripping out or relocating anything until the decision is
recorded here.

- **Option A — Retire.** Remove the learnings loop entirely. Delete the Step 4
  apply + Step 7 learn integration from `mstack-run`, deprecate the
  `mstack-learned-patterns` skill (stub-with-redirect, matching how
  `mstack-simplify-code` was deprecated), and remove/retire `learnings.sh`. All
  knowledge routes to committed docs (the wrap-up model, now the whole system's
  model). Simplest end state; loses the auto-apply-at-implement-time affordance.
- **Option B — Relocate.** Keep the auto-apply/auto-prune machinery but change
  its store from gitignored JSONL to **committed, human-readable topic docs**
  (progressive disclosure, per the wrap-up router). Preserves the "surface past
  pitfalls to the implementing agent at Step 4" value while making the record
  durable and reviewable. More machinery to keep; risks noisy machine-managed
  churn in committed history and docs that read as a capture, not documentation.
- **Option C — De-emphasize only.** Leave the subsystem in place but downgrade it
  to an explicitly-secondary, opt-in store and document that committed docs are
  primary. Smallest change; the parallel uncommitted store persists.

Recommendation to weigh in review: the user's stated goal ("what should go into
repo documentation is where it's committed") points at **A or B over C**. A is
cleanest; B is warranted only if the Step-4 auto-apply affordance is judged worth
its complexity. The unique value B preserves that A drops: learnings surfaced to
the implementer keyed by the plan's files, without a human authoring them —
though `mstack-run` already reads `AGENTS.md`/`CLAUDE.md`, so committed docs cover
much of the same ground when read.

### Footprint (what the chosen option must touch)

The subsystem is woven across the pipeline; a full accounting, so nothing is
missed and no partial rip-out leaves dangling references:

- `skills/mstack-run/scripts/learnings.sh` — the store manager (list/search/
  prune/append/get/bump).
- `skills/mstack-learned-patterns/SKILL.md` — the skill and its mstack-run
  integration contract (Step 4 prune+apply, Step 7a/7b learn).
- `skills/mstack-run/SKILL.md` and `references/subagent-prompt.md` — the Step
  4/7 call sites.
- `skills/mstack-status/SKILL.md` and `scripts/status.sh` — surface the
  learnings count in the dashboard.
- `skills/mstack-investigate/SKILL.md`, `skills/mstack-plan-doctor/SKILL.md`
  (+ `references/frame-review.md`), `skills/mstack-plan-multi/SKILL.md` — all
  reference learnings.
- `skills/mstack-run/scripts/init.sh` — provisions the store / gitignore entry.
- `skills/mstack-run/references/health-gate-spec.md` — mentions the pattern.
- `AGENTS.md`, `README.md`, `CHANGELOG.md` — doc references to reconcile.
- Existing `.mstack/learnings.jsonl` contents on this and other machines — a
  migration question (harvest into committed docs, or discard?) that the chosen
  option must answer.

## Acceptance criteria

- [ ] **The fork is decided and recorded** in this plan (A, B, or C), ratified by
      the eng review gate, before any implementation.
- [ ] **The pipeline is internally consistent** with the wrap-up router's
      doc-first default — no skill still presents the gitignored learnings store
      as the primary home for durable project knowledge.
- [ ] **No dangling references** to any removed/relocated component across the
      files listed in Footprint (grep-clean for `learnings.sh`,
      `learned-patterns`, `learnings.jsonl` against whatever the option removes).
- [ ] **Existing `.mstack/learnings.jsonl` content has a stated disposition**
      (migrated to committed docs, or explicitly discarded — not silently
      orphaned).
- [ ] **`AGENTS.md`/`README.md`/`CHANGELOG.md` reflect the new model**, using
      progressive disclosure (pointers to topic sub-docs, AGENTS.md kept lean).
- [ ] Shell helpers still pass `bash -n` and `shellcheck`; smoke checks
      (`status.sh`, `pick-next.sh`, `bin/mstack-codex-smoke`) still run.

## Notes

- This plan likely **decomposes** — the decision spike, the `mstack-run`
  Step 4/7 change, the `learned-patterns` deprecation, the cross-skill reference
  cleanup, and any migration are separable. Run `/mstack-plan-multi` on it once
  the fork is decided if it is too large for one pass.
- The wrap-up half of this concern is already shipped (`74e04dc`); this plan is
  deliberately scoped to *the rest of the pipeline*, not wrap-up.
- Progressive-disclosure doc conventions to mirror: see the wrap-up router's
  **Progressive-disclosure doc routing** section (topic/architecture sub-docs,
  AGENTS.md one-line pointers, docs that read as documentation not as captures).
