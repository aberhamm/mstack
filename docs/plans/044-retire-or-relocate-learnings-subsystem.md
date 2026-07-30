---
id: 044
title: retire the learnings subsystem so durable knowledge lives in committed docs
status: pending
blocked-by: [083]
priority:
goal:
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-22
qa: manual
reviews:
  - type=eng verdict=approved date=2026-07-22 by=mstack-review
---

## Requirements

The mstack learnings subsystem writes durable project knowledge to
`.mstack/learnings.jsonl`, and `.mstack/` is **gitignored** (`.gitignore:6`). So
every "learning" the pipeline extracts is **uncommitted, per-machine, invisible
in review, and gone on a fresh clone**. Knowledge that belongs to the repository
lives in a store the repository cannot see — the same invisible-state failure
class mstack already abolishes elsewhere (the review-gate doctrine: a declaration
under gitignored `.mstack/` "would be invisible to review, per-checkout, and gone
on a fresh clone").

The wrap-up router was the first place this surfaced and is already fixed (commit
`74e04dc`): durable knowledge routes to a **committed doc via progressive
disclosure**, with `mstack-learned-patterns`/host-memory demoted to fallbacks.
This plan makes the rest of the pipeline consistent — today `mstack-run` still
runs the learnings loop as a primary mechanism, so the two halves disagree.

### Decision (ratified by eng review, 2026-07-22): RETIRE

Of the three options weighed — retire (A), relocate the store to committed docs
(B), de-emphasize (C) — **A (retire) is chosen.** Rationale recorded so a future
session does not re-litigate it:

- The subsystem is **accidental complexity**: a parallel knowledge store plus
  prune/decay/confidence machinery that existed only because knowledge had
  nowhere committed to go. The wrap-up router now gives it a committed home, so
  the machinery is redundant.
- It is a **DRY violation**: two stores (gitignored JSONL + committed docs) for
  the same class of knowledge.
- The one thing it uniquely did — surface past pitfalls to the implementing agent
  at Step 4, keyed by the plan's files — is **replicable via committed
  progressive-disclosure docs**, which `mstack-run` already reads
  (`AGENTS.md`/`CLAUDE.md`).
- **B was rejected:** retargeting decay/dedup/confidence into human-readable
  markdown is *more* machinery and produces churny machine-managed commits and
  docs that read as a capture, not documentation — fighting the goal of docs that
  "look good architecturally, outside of the concept of learnings."
- **C was rejected:** it leaves the gitignored parallel store in place and does
  not fix the complaint.

The accepted cost of A: knowledge capture becomes **human-in-the-loop** (via the
harvest's propose-by-default doc edits) rather than fully automatic. That is the
intended trade — committed and reviewed over automatic and ephemeral.

## Design

Retire the subsystem via a **strangler-fig sequence** (make it inert, migrate,
deprecate, remove), not a big-bang delete, so no stage leaves the pipeline in a
broken or dangling-reference state.

**Files expected to change:**

- `skills/mstack-run/scripts/learnings.sh` — DELETE (the store manager).
- `skills/mstack-learned-patterns/SKILL.md` — replace with a deprecation stub
  that redirects to the committed-docs model, mirroring how
  `skills/mstack-simplify-code` was deprecated (kept for back-compat, redirects).
- `skills/mstack-run/SKILL.md` — remove the Step 4 prune+apply and Step 7a/7b
  learn integration points.
- `skills/mstack-run/references/subagent-prompt.md` — remove the learnings
  apply/learn references.
- `skills/mstack-status/SKILL.md` + `skills/mstack-run/scripts/status.sh` —
  remove the learnings-count surface from the dashboard.
- `skills/mstack-plan-doctor/SKILL.md` — remove Step 2b (learnings check); if a
  pitfall-surfacing affordance is still wanted, repoint it at the relevant
  committed topic doc rather than the JSONL store.
- `skills/mstack-plan-doctor/references/frame-review.md`,
  `skills/mstack-plan-multi/SKILL.md`, `skills/mstack-investigate/SKILL.md`,
  `skills/mstack-run/references/health-gate-spec.md` — remove learnings
  references.
- `skills/mstack-run/scripts/init.sh` — stop provisioning the learnings store.
- `skills/mstack-wrap-up/SKILL.md` — update the router's FALLBACK line: with
  `learnings.sh` gone, drop the `mstack-learned-patterns` helper fallback;
  genuinely-personal cross-project prefs fall back to host memory only. (This is
  a small consistency edit to keep the router from dangling — NOT a reopening of
  the wrap-up router design shipped in `74e04dc`.)
- `AGENTS.md`, `README.md` — update to the doc-first model; document the
  progressive-disclosure convention (topic sub-docs, AGENTS.md pointers) if not
  already captured.
- `CHANGELOG.md` — entry.

**Out of scope:**

- The wrap-up router's doc-first primary routing — already shipped (`74e04dc`);
  this plan only touches its now-dangling fallback line.
- Any NEW documentation structure beyond what retiring requires — writing the
  actual topic docs is the harvest's job over time, not this removal plan.
- The global `~/.mstack/learnings.jsonl` cross-project store as a concept — it
  dies naturally with `learnings.sh` (its only reader/writer); no separate
  migration of the global file is promised here beyond noting it is gone.

## Tasks

1. **Make the loop inert.** Remove the Step 7 "learn" extraction and the Step 4
   "apply" (and prune) integration from `mstack-run/SKILL.md` and
   `references/subagent-prompt.md`, so no new learnings are written or read.
2. **Migrate, then discard.** Read `.mstack/learnings.jsonl` (project; note the
   global file too). Triage: fold anything still durable and true into the
   relevant committed progressive-disclosure doc as a proposed edit; discard the
   rest. Record the disposition in the PR/commit so it is not silently orphaned.
3. **Deprecate the skill.** Replace `mstack-learned-patterns/SKILL.md` with a
   back-compat stub that redirects to the committed-docs model (mirror
   `mstack-simplify-code`).
4. **Remove read sites + helper.** Delete `learnings.sh`; remove the
   learnings-count from `status.sh` + `mstack-status`; remove plan-doctor Step 2b
   and the `frame-review.md`/`plan-multi`/`investigate`/`health-gate-spec.md`
   references; update `init.sh`.
5. **Reconcile docs + the wrap-up fallback.** Update the wrap-up router fallback
   line (drop the deleted `learnings.sh` helper reference); update
   `AGENTS.md`/`README.md` to the doc-first model + progressive-disclosure
   convention; add a `CHANGELOG.md` entry.
6. **Grep-clean + smoke.** Confirm no dangling references remain and the shell
   helpers and smoke checks still pass (see Verification).

## Verification

- [cmd] `grep -rn 'learnings\.sh\|learnings\.jsonl' skills/ bin/ setup` → no
  matches (archived plans and CHANGELOG history are exempt; scope the grep to
  live skill/bin/setup sources).
- [cmd] `grep -rln 'learned-patterns' skills/` → only
  `skills/mstack-learned-patterns/SKILL.md` (the deprecation stub) and any
  intentional "Related skills" mentions remain; no live integration call sites.
- [cmd] `bash -n skills/mstack-run/scripts/*.sh bin/mstack-update-check setup` →
  exit 0.
- [cmd] `shellcheck skills/mstack-run/scripts/*.sh` → exit 0.
- [cmd] `bash skills/mstack-run/scripts/status.sh` → runs to completion with no
  learnings-related error (the count line is gone, not erroring).
- [cmd] `bash skills/mstack-run/scripts/pick-next.sh` → runs (exit 10 on an empty
  backlog is expected and fine).

## Acceptance criteria

- [ ] No skill or script still presents the gitignored learnings store as a
      home for durable project knowledge; the pipeline is consistent with the
      wrap-up router's doc-first default.
- [ ] `learnings.sh` is removed and `mstack-learned-patterns` is a redirecting
      deprecation stub; no live call site invokes either.
- [ ] The grep-clean and smoke checks in Verification all pass.
- [ ] The existing `.mstack/learnings.jsonl` content has a stated disposition
      (migrated to committed docs, or explicitly discarded — not silently
      orphaned).
- [ ] `AGENTS.md`/`README.md`/`CHANGELOG.md` reflect the doc-first model using
      progressive disclosure (pointers to topic sub-docs, AGENTS.md kept lean).

## Notes

- This plan may **decompose** (inert-loop change, migration, skill deprecation,
  reference cleanup, doc reconciliation are separable). Run `/mstack-plan-multi`
  on it if it is too large for one `mstack-run` pass.
- Progressive-disclosure conventions to mirror: the wrap-up router's
  **Progressive-disclosure doc routing** section (topic/architecture sub-docs,
  AGENTS.md one-line pointers, docs that read as documentation not captures).
