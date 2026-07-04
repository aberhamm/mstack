---
id: 037
title: Approved plans are always committed — no dirty resting state
status: in-progress
blocked-by: [034, 035, 036]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
---

## Requirements

Once a plan is written up **and** approved (its review gate cleared /
verdict recorded), that approval must be persisted to git. "Approved but
uncommitted" — a plan whose gate reads cleared but whose frontmatter change and
review record sit dirty in the working tree — must not be a valid resting state.

Today `mstack-plan-doctor` Step 5 edits a plan's frontmatter to clear reviews
(and, after plan 035, records the verdict) but does **not** commit. The approval
therefore lives only in the working tree: a crash, context switch, or a
`git checkout`/stash loses it, or leaves an ambiguous state where the gate looks
cleared but nothing is recorded in history. The paper trail the rest of the
backlog relies on (git log + completion tags) gets a hole exactly at the
approval step.

This is the approval-stage analogue of plan 036 (which persists *completion*).
Together they close the lifecycle: authored (may be dirty, review-pending) →
**approved + committed (this plan)** → executed → completed + committed + tagged
(036).

**Acceptance criteria:**

- [ ] When `mstack-plan-doctor` records an approval and clears a gate (the 035
      path), it commits the plan file and its review record in the same step —
      explicit file list, conventional message
      (e.g. `chore(plan NNN): approve (eng)` with a `Refs: docs/plans/<file>`
      trailer). No push (solo-on-main convention).
- [ ] **"Approved" is defined as "has ≥1 recorded `reviews:` verdict"**, NOT as
      "gate reads cleared". A plan with `needs-review: none` and no
      `review-required` (any legacy or no-review plan) reads "cleared" but has no
      recorded verdict — it must NOT be treated as approved, or `assert-committed`
      would force-commit merely-authored plans and violate the exemption below.
- [ ] Records are committed frontmatter (`reviews:`), per plan 034 — **not**
      `.mstack/reviews/*.json`, which is gitignored (`.gitignore:6`) and can never
      be committed or diffed against `HEAD`. So `assert-committed` is a
      single-path check on the plan file.
- [ ] A deterministic check — `review-gate.sh assert-committed <plan>` — exits
      nonzero when a plan has a recorded verdict but uncommitted changes to the
      plan file (working tree vs `HEAD`). Fail closed.
- [ ] `mstack-status` / `mstack-backlog` / `mstack-plan-doctor` audit surfaces any
      "approved but uncommitted" plan as an actionable warning and offers to
      commit it — so pre-existing dirty approvals get healed, not just newly
      created ones.
- [ ] `mstack-run` invokes `assert-committed` for a plan immediately before the
      execution edit (not cached earlier in the run): a plan in an
      approved-but-uncommitted state is committed (or flagged and halted) rather
      than silently run against a dirty tree.
- [ ] Authoring-only state is explicitly **exempt**: a written-but-not-yet-approved
      plan (no recorded verdict) is allowed to sit uncommitted (that is the
      review-pending state by design). The invariant binds only once a verdict is
      recorded.

## Design

**Commit at the approval choke point.** The single place a gate clears is
plan-doctor Step 5 (extended by 035 to record the verdict). Plan 037 adds the
commit there, right after the record + frontmatter edit, so approval and its
persistence are atomic from the user's perspective.

**`assert-committed`** uses `git status --porcelain -- <plan> <record-path>`; if
the gate is recorded-cleared and either path is dirty, it fails with a message
telling the caller to commit. This is what makes "approved but uncommitted"
detectable anywhere, not just at the moment of approval.

**Interaction with 036 and the worker.** There are *three* plan-file commit
sites to reconcile: (1) this plan's approval-commit at plan-doctor time
(pre-execution); (2) the worker's own block-path commits when it sets
`needs-review` on an incomplete spec/stale seam (`SKILL.md:445-448,488-491`);
(3) 036/Step 7a's completion-commit. Distinct times and content, so they don't
fight — but state the ordering: the approval-commit lands before the worker picks
the plan, so `assert-committed` at execution start sees a clean tree.

**TOCTOU caveat.** `assert-committed` is point-in-time; a `git checkout`/stash
after it passes could re-dirty the approval. On solo-main this is low-risk, and
plan 038's retroactive audit catches an approved-but-drifted plan regardless.
Check `assert-committed` immediately before the execution edit, and rely on 038's
audit for drift that happens outside any single run.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: commit the plan + record after clearing.
- `skills/mstack-run/scripts/review-gate.sh`: add `assert-committed`.
- `skills/mstack-status/SKILL.md`, `skills/mstack-backlog/SKILL.md`: audit +
  heal the approved-but-uncommitted state.
- `skills/mstack-run/SKILL.md`: call `assert-committed` before executing a plan.
- `AGENTS.md`: document the "approved ⇒ committed" invariant and the exemption
  for review-pending plans.

**Out of scope:** forcing a commit for merely-authored (unapproved) plans;
changing `mstack-run`'s existing success-commit in Step 7a (it already commits on
completion); auto-pushing.

**Shared-file coordination.** `mstack-plan-doctor/SKILL.md`, `mstack-run/SKILL.md`,
`mstack-status/SKILL.md`, `mstack-backlog/SKILL.md`, `AGENTS.md`, and
`review-gate.sh` are edited by several plans in this goal. Edit by **text anchor,
not line number**, and re-read each shared file immediately before editing (this
plan runs after 036, which edits the same Step 7a region).

## Tasks

1. Add `assert-committed` to `review-gate.sh`.
2. Extend plan-doctor Step 5 to commit the plan + review record after clearing.
3. Add the approved-but-uncommitted audit + heal to status/backlog/doctor.
4. Call `assert-committed` before execution in `mstack-run`.
5. Document the invariant and the authoring exemption in `AGENTS.md`.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/review-gate.sh`; `shellcheck` clean.
- `[cmd]` a fixture plan with a recorded `reviews:` verdict and a dirty plan file
  makes `assert-committed` exit nonzero; after committing, it exits 0.
- `[cmd]` a written-but-unapproved fixture (no recorded verdict) that is dirty
  makes `assert-committed` exit 0 (exemption holds — not forced to commit), and
  a legacy fixture (`needs-review: none`, no `review-required`, no verdict) is
  likewise treated as unapproved, not force-committed.
- `[assert]` a scripted plan-doctor approve run leaves the plan file (with its
  frontmatter `reviews:` record) committed — working tree clean for that path
  afterward; `git log -1` shows the approval commit.
- `[assert]` `mstack-status` lists an approved-but-uncommitted fixture in its
  audit output.
