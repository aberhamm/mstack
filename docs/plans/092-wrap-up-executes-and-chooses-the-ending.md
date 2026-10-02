---
id: 092
title: Wrap-up executes approved cleanups and offers close-or-handoff as one ending
status: done
blocked-by: []
priority:
goal: wrap-up-single-entry-point
allows-migrations: false
needs-review: none
created: 2026-10-02
completed: 2026-10-02
reviewed: false
qa: automated
---

## Plain-English Summary

Today, closing out a session in this repo takes two skills: `mstack-wrap-up`
to find leftover cleanup items and get a cleared-to-close verdict, then
`mstack-handoff` to actually hand the remaining work to a fresh session —
and even wrap-up's own cleanup findings are mostly *proposed*, not done, so
a third step (manually applying each proposal) is often needed too. This
plan makes `mstack-wrap-up` the single end-of-session entry point: it still
mines the session for findings exactly as before, but now it actually
applies the ones the user approves (including doc edits and, for clearly
disposable session scaffolding, deletion — never without the user naming
that item explicitly), and its final question is no longer just "close?" —
it is "close this session, or hand the rest off to a fresh one?", with
hand-off folding in everything the harvest just found.

**What changes in the code:** Three prose skill files change behavior, no
new scripts are added. `mstack-wrap-up/SKILL.md`: the findings
apply-question now executes every approved finding itself (doc edits join
the routes that already executed in-flow; a new, narrowly-scoped litter
deletion path is added for untracked session scaffolding); the Git-hygiene
commit question folds in files the routes themselves just wrote, so there
is one disposition question instead of a deferred one; the Ending section
is replaced with a single question offering Close / Hand off / Stay open,
asked unconditionally in terminal mode (previously Hand off only appeared
if a Pass A/B finding happened to name it). `mstack-handoff/SKILL.md` and
`mstack-stash/SKILL.md` get their cross-reference lines reworded so the
trio's docs still describe each other accurately, and `README.md` gets its
one-line description of `/mstack-wrap-up` updated to match. A new smoke
test (`wrapup-ending-smoke.sh`) pins the load-bearing directives in the
rewritten prose the same way `brief-content-smoke.sh` already pins Rule 4's.

## Requirements

A user running `/mstack-wrap-up` at the end of a session should not need a
second skill invocation to either (a) get its findings actually applied, or
(b) hand off instead of closing. Concretely:

- [x] The findings apply-question ("apply all / pick / none", already
  present at `skills/mstack-wrap-up/SKILL.md` under **Interaction
  budget**) results in **every selected finding actually being applied**,
  not merely proposed. Specifically, a doc-edit finding is written to disk
  when selected, in-flow — the existing "Doc-edit proposals never block
  the flow" deferral (`skills/mstack-wrap-up/SKILL.md`, the section with
  that exact heading) is removed; doc edits execute at the same point in
  the flow as the other routes (**Route execution order**).
- [x] A **litter** finding (Pass A category 1, "scaffolding created that
  should now be deleted", or a Pass B `wrapup-scan.sh` `artifacts` entry —
  see `ARTIFACT_PATTERNS` in `skills/mstack-run/scripts/wrapup-scan.sh`)
  can now be **deleted** by wrap-up itself, but only when: (a) the path is
  **untracked** (confirmed via `git ls-files --error-unmatch`, never a
  tracked file — a tracked obsoleted file keeps routing through
  `mstack-plan-new`/report-only as today), and (b) the user **individually,
  explicitly** selected that specific item — a litter-deletion finding is
  **never** included in a blanket "apply all" (the `>4 findings` triage
  branch already documented at `skills/mstack-wrap-up/SKILL.md` under
  **Interaction budget**); "apply all" with a pending deletion applies
  every non-deletion finding and calls the deletion(s) out separately as
  needing an individual pick. Deletion is an exact-path `rm --`, never a
  glob, never `git clean`.
- [x] The git-hygiene commit question (`skills/mstack-wrap-up/SKILL.md`,
  **Git hygiene before the ending**) covers, as one combined file list,
  both the pre-existing dirt it already scans for *and* any new paths the
  findings routes just wrote in this same run (doc edits applied, a
  `mstack-plan-new`/`mstack-changelog`/`mstack-stash` write). This
  terminal-mode case replaces the old deferred "offer to commit what the
  routes wrote" for terminal sessions; that deferred offer is kept, but
  reworded to state it now applies **only to mid-session mode**, where no
  git-hygiene step runs at all.
- [x] The **Ending** section of `skills/mstack-wrap-up/SKILL.md` is
  replaced with one ending question, asked unconditionally in terminal
  mode (not gated on a Pass A/B finding having named hand-off), offering
  up to three options depending on the existing `cctrl-status` probe
  already documented in that file:
  - `available=true, can_close_self=true`: Close session `<id>` / Hand off
    remaining work / Stay open — with any unpushed-commit warning folded
    into the Close option's label exactly as today.
  - `available=true, can_close_self=false`: Hand off remaining work / Stay
    open (never offer Close — unchanged rule).
  - `available=false`: Hand off remaining work (checkpoint-only; no spawn)
    / Stay open (the user closes themself).
  Picking Hand off invokes `mstack-handoff` exactly as it is invoked
  today's "handoff route" (checkpoint mode, no invented prefill API, cctrl
  spawn mode when available) — this plan does not touch
  `skills/mstack-handoff/SKILL.md`'s mechanics or
  `skills/mstack-run/scripts/handoff.sh` at all. The now-redundant "Dedup
  rule" (which made selecting an `mstack-handoff` finding at the findings
  step pre-empt the ending question) is removed along with the Router row
  that triggered it, since hand-off is no longer something a *finding*
  routes to — it is always available at the one ending question.
  The still-binding budget ceiling (2 findings + 1 git-hygiene + 1 ending
  = 4 questions max) is unchanged; this is still exactly one question.
- [x] `skills/mstack-handoff/SKILL.md` and `skills/mstack-stash/SKILL.md`
  keep working standalone (`/mstack-handoff`, `/mstack-stash` invoked
  directly, with no wrap-up involvement, are untouched) and their
  cross-reference text describing wrap-up is still accurate given the
  above; `README.md`'s one-line `/mstack-wrap-up` row
  (`README.md`, the mstack skills table) reflects that wrap-up now applies
  approved cleanups and ends in close-or-handoff, not just a verdict.
- [x] A new smoke test, `skills/mstack-run/scripts/wrapup-ending-smoke.sh`,
  modeled on `skills/mstack-run/scripts/brief-content-smoke.sh` (whitespace
  normalized, substring-matched, never asserting the prose reads well —
  only that load-bearing phrases survive), pins: the removal of the
  doc-edit deferral and its replacement with in-flow application; the
  untracked-only, never-in-apply-all litter-deletion rule; the git-hygiene
  "combined file list" wording; and the three-branch unconditional ending
  question. It is added to the suite list `AGENTS.md`'s **Development
  Commands** already runs for every change under `scripts/`.

## Design

**Why fold doc-edit application into the same in-flow mechanism as the
other routes, instead of adding a fourth special case?** The other four
sinks (`mstack-plan-new`, `mstack-changelog`, `mstack-stash`, the old
`mstack-handoff` finding) already write when their route runs, during
**Route execution order**, bounded by the same approval that selected them
in the findings question. Doc edits were the one outlier, deferred to a
later conversational "apply #2" purely because no skill owns that write —
wrap-up performs it directly via Edit. Removing the special case is a
subtraction, not a new mechanism: the diff is still rendered before
writing (unchanged), the write now simply happens at the same point every
other route's write already happens.

**Why is litter deletion scoped to untracked paths only, and why is it
excluded from blanket "apply all"?** An untracked file this session
created is wholly reversible to *propose* removing (nothing is lost that
git could recover either way — it was never committed), which is why Pass
A/Pass B already classify it `litter` with no extra gate. But *actually
deleting* it is still a one-way action from the user's point of view, and
the operator brief (and `AGENTS.md`'s own "Guarded deletes only, on exact
paths: no globs, no dirname-derived paths" discipline, written for exactly
this kind of worker) is explicit that deletion needs an individual,
explicit yes — a blanket "apply all" that also happens to contain a
deletion is not that. A tracked file is excluded entirely from direct
deletion by this skill: removing a tracked file is a commit-worthy change
in its own right (it needs `git rm`, a message, and arguably review), and
that is exactly what `mstack-plan-new`'s "cleanup too big for now" route
or a plain report-only mention already cover — this plan does not add a
`git rm` capability to wrap-up.

**Why fold "what the routes wrote" into git-hygiene instead of keeping the
old deferred commit offer for terminal mode too?** The deferred offer
existed because doc edits (and conversationally-applied routes) wrote
*after* the flow had already ended, outside any question budget. Now that
every route — doc edits included — writes **before** the verdict (**Route
execution order** is unchanged: routes run after the findings question(s),
before the verdict), by the time git-hygiene runs (after the verdict,
before the ending) those writes already exist in the working tree. Git
hygiene already re-uses the Pass B scan rather than re-scanning; the fix
is simply widening its file list to include the paths this run's routes
are known (from the in-session "Say what this run wrote" bookkeeping
already required by the current file) to have just written, so one
disposition question (commit / stash / leave-as-is) covers all of it. Mid
session mode never reaches git-hygiene (it is explicitly skipped there
today), so mid-session keeps the deferred post-flow commit offer — this
plan narrows that section's scope to mid-session rather than deleting it.

**Why is Hand off always offered rather than only when a finding named
it?** The old "Dedup rule" made `mstack-handoff` reachable from the ending
only if the recall/scan pass happened to surface an "unfinished work"
finding during Pass A/B — recall is necessarily incomplete (it is a
judgment call, not a scan), so a session with real follow-on work but no
explicit finding naming it got no hand-off offer at all. The ending
question already fires unconditionally today for the `available=true,
can_close_self=true` branch (close y/n every time, clean session or not);
this plan adds Hand off as a sibling option on that same,
already-unconditional question, and extends unconditional firing to the
`can_close_self=false` and `available=false` branches too (today, both are
either silent or gated on a finding; after this plan, both always ask —
just never offering Close). Hand-off's own content-gathering (already
documented, unchanged) folds in whatever the harvest found via session
context — no prefill parameter is invented.

**Out of scope:** `skills/mstack-run/scripts/handoff.sh` and
`skills/mstack-run/scripts/wrapup-scan.sh` (no script changes — this is a
pure prose/behavior change in how wrap-up uses the existing helpers);
`skills/mstack-handoff/SKILL.md`'s own internals (spawn mode, checkpoint
format, resume flow); `cctrl-session-end` (external repo, unaffected);
any change to the review-gate / completion-enforcement family
(plans 034–039, 043, 045). This plan does not touch plan review state,
matching wrap-up's existing hard guardrail.

**Files expected to change:**

- `skills/mstack-wrap-up/SKILL.md`: frontmatter `description` (reflects
  execution + guarded deletion + close-or-handoff ending, not
  propose-by-default-only); the doc-edit deferral section removed; a new
  "Litter deletion" subsection; **Git hygiene** widened to include route
  writes with a reworded "combined file list"; **Ending** rewritten to one
  unconditional three-branch question; the Router table's
  `mstack-handoff` row removed (now six rows) with a one-line pointer to
  the new Ending section; the "Dedup rule" and "handoff route" subsection
  removed; **Guardrails** and **What NOT to do** updated for the new
  delete capability and the folded commit question.
- `skills/mstack-handoff/SKILL.md`: no mechanics change; only the
  description's framing of how wrap-up invokes it (if the existing text
  needs a word changed to stay accurate — read it fresh before editing;
  do not touch anything else in that file).
- `skills/mstack-stash/SKILL.md`: the "Not this skill if" line's
  description of wrap-up as "the terminal one", checked for continued
  accuracy and reworded only if the new ending behavior makes it
  misleading.
- `README.md`: the `/mstack-wrap-up` row in the skills table.
- `skills/mstack-run/scripts/wrapup-ending-smoke.sh` (new): content-pinning
  smoke test, modeled on `brief-content-smoke.sh`.
- `AGENTS.md`: add the new smoke test to the **Development Commands**
  suite list.

## Tasks

1. Rewrite `skills/mstack-wrap-up/SKILL.md`: frontmatter description;
   remove the doc-edit deferral; add the litter-deletion subsection; widen
   Git hygiene; replace Ending; trim the Router table and remove the
   Dedup-rule/handoff-route subsection; update Guardrails/What-NOT-to-do.
2. Review `skills/mstack-handoff/SKILL.md` and
   `skills/mstack-stash/SKILL.md` cross-reference text; edit only what is
   now inaccurate.
3. Update the `/mstack-wrap-up` row in `README.md`.
4. Write `skills/mstack-run/scripts/wrapup-ending-smoke.sh` pinning the
   directives listed in Requirements; wire it into `AGENTS.md`'s suite
   list.
5. Run the full smoke suite plus `bash -n`/`shellcheck` on the new script;
   run the new smoke test standalone and confirm it fails against the
   pre-change file (characterize) before confirming it passes post-change.
6. Opus-subagent review of the full diff; fix required findings.

## Verification

- [cmd] bash -n skills/mstack-run/scripts/wrapup-ending-smoke.sh
- [cmd] shellcheck skills/mstack-run/scripts/wrapup-ending-smoke.sh
- [cmd] bash skills/mstack-run/scripts/wrapup-ending-smoke.sh
- [cmd] bash skills/mstack-run/scripts/script-mode-smoke.sh
- [cmd] bash skills/mstack-run/scripts/wrapup-scan-smoke.sh
- [assert] grep -q "untracked" skills/mstack-wrap-up/SKILL.md
- [assert] grep -q "Stay open" skills/mstack-wrap-up/SKILL.md
- [manual] Read the full rewritten **Ending** and **Git hygiene** sections
  end to end and confirm the question budget arithmetic in **Interaction
  budget** (0–2 findings + 1 git-hygiene + 1 ending, max 4) still adds up
  after the edits.
