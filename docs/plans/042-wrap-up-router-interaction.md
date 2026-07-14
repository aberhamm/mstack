---
id: 042
title: mstack-wrap-up router + interaction layer — sinks, question budget, close offer
status: done
blocked-by: [041]
priority:
goal: wrap-up-skill
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-14
completed: 2026-07-14
reviewed: false
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-14 by=mstack-review
---

## Requirements

Plan 041 ships `mstack-wrap-up` as report-only: it harvests and prints
findings with suggested destinations, but routes nothing and asks nothing.
This plan adds the two layers that make it a conductor: the **router over
existing sinks** (no new state directory, no new artifact type) and the
**interaction layer** (0–2 button-only AskUserQuestion interactions, the
cctrl close offer, and the no-cctrl handoff-save question).

**Acceptance criteria:**

- [ ] **Router table** in `skills/mstack-wrap-up/SKILL.md` mapping finding
      type → sink, exactly the locked seven: unwritten learnings →
      `mstack-learned-patterns`; shipped-but-unlogged changes →
      `mstack-changelog`; docs made stale by the session → a proposed edit
      (shown as a diff/summary, applied only on approval); user
      preferences/decisions worth persisting → host agent memory, defined
      operationally: route there only when the RUNNING agent already has a
      documented persistent-memory mechanism in its own instructions (e.g.
      Claude Code sessions that announce a memory directory in their system
      prompt); no probing of foreign agent config dirs. Otherwise fall back
      to a learned-patterns entry (agent-neutral per repo convention);
      unfinished
      work with follow-on value → `mstack-handoff`; ideas not ready to plan
      → `mstack-stash`; cleanup too big for now → `mstack-plan-new`.
- [ ] **Write policy:** propose-by-default for every sink that writes to the
      repo or docs; the SINGLE exception is `mstack-learned-patterns`, which
      may write unprompted (prunable, low blast radius). The exception is
      stated as an exception, not an example.
- [ ] **Interaction budget, button-only:** 0–2 FINDINGS questions plus at
      most 1 ENDING question (close offer or handoff-save — mutually
      exclusive), so no path ever exceeds 3 questions total and most runs
      ask 0–1. Zero findings → zero findings-questions (~3-line clean
      ending); 1–4 findings → ONE multiSelect listing the findings directly;
      >4 findings → ONE triage question (Apply all / Pick / Report only),
      and "Pick" spends the second findings-question: a multiSelect of the
      top 4 findings by value, with the remainder explicitly listed as
      report-only. Never a third findings-question; never free-text typing
      required on hosts with AskUserQuestion (hosts without it fall back to
      numbered prose where a reply is a number/letter list — minimal typing
      is the floor there, same budget arithmetic). This resolves the
      4-option-cap concern flagged at design time: the cap is honored by
      triage-then-top-4, not by paginating.
- [ ] **Doc-edit proposals never block the flow (propose-by-default meets
      the budget):** selecting a doc-edit finding renders its READY diff in
      the final report; the flow ends without waiting on it. The user
      applies any proposal afterward in normal conversation ("apply #2"),
      at which point the main agent performs the Edit — explicit approval
      before any write, zero in-flow approval prompts.
- [ ] **cctrl close offer** (only when `cctrl-status` reported
      `available=true` AND `can_close_self=true`): after the verdict, ONE
      yes/no question that shows the current session id and folds any
      warning into the question itself (e.g. "2 commits unpushed — close
      anyway?"). Yes → `handoff.sh close-self`. `can_close_self=false`
      (session not closable from within; gate purely on the field — e.g.
      fleet-managed) → verdict + wait, no offer, no mention.
      `available=false` → the doctrine from 041 stands: closing is never
      mentioned. The close question is EXCLUDED from the 0–2 findings
      budget (it is the ending, not a finding), but the skill still asks at
      most one ending question total.
- [ ] **No-cctrl ending:** when cctrl is absent and the harvest surfaced
      follow-on work, the ONE allowed ending question is "save a handoff
      checkpoint before you quit?" — yes routes into `mstack-handoff`
      checkpoint mode (follow-on items travel via session context per the
      no-prefill-API criterion below). No follow-on work
      → no question, verdict only.
- [ ] **Mid-session mode** asks the findings questions (routing is still
      useful mid-session) but never asks an ending question and never
      offers a close.
- [ ] **Ending-question dedup and route ordering:** if an "unfinished work →
      mstack-handoff" finding was selected and routed, the no-cctrl
      handoff-save ending question is SKIPPED (the handoff already
      happened — never ask twice). Routes execute after the findings
      question(s); the mstack-handoff route always runs LAST among selected
      routes since it transfers interaction control, and wrap-up asks
      nothing after the transfer.
- [ ] Routed sink invocations use each sink's real entry point (Skill
      invocation or documented helper). The `mstack-handoff` route invokes
      the handoff skill in checkpoint mode WITHOUT claiming a prefill API
      (none exists): the follow-on items are already in session context,
      and handoff's own content-gathering step ("fold open items into Next
      step") picks them up. The wrap-up skill states this explicitly so a
      worker doesn't invent a parameter contract.
- [ ] **Budget boundary:** the 0–2 question budget binds `mstack-wrap-up`'s
      OWN flow. Once the user opts into a routed skill (e.g. chooses the
      handoff), that skill's own questions (delivery mode, WIP-commit) run
      under its own rules — a user-consented handover, not a budget
      violation. Wrap-up itself asks nothing further after the transfer,
      and the skill text says so.
- [ ] Guardrails from 041 hold unchanged: routing NEVER touches plan
      `status`/`needs-review`/`review-required`/`reviews`; nothing is
      committed with `git add .`; nothing is pushed.
- [ ] Frontmatter `allowed-tools` (set in 041: Bash, Read, Glob, Grep,
      Agent) is extended with the tools this layer needs: `AskUserQuestion`
      (the questions), `Skill` (routed sink invocations), and `Write`
      (approved doc-edit proposals) — matching the `mstack-plan-doctor`
      precedent of listing every tool the flow uses.

## Design

Single-file prose change layered onto 041's SKILL.md: the "suggested
destination" column becomes live routes, and the flow gains its decision
points. Keep 041's flow order intact — recall, scan, merge, THEN the
findings question(s), routing, verdict, ending.

**Files expected to change:**

- `skills/mstack-wrap-up/SKILL.md`: router table, interaction rules,
  ending logic (cctrl close offer / no-cctrl handoff question / mid-session
  no-ending), sink invocation notes.

Layering + contract notes:

- 042 layers onto the file 041 CREATED: the worker re-reads the post-041
  `SKILL.md` and inserts/extends sections, preserving 041's wording and
  structure — never a from-scratch rewrite.
- cctrl data source, named exactly: `handoff.sh cctrl-status` key=value
  lines (`available`, `session`, `target`, `agent`, `cwd`,
  `can_close_self`); the close question shows the `session` value; close
  executes `handoff.sh close-self`. The 041 state-vs-action rule applies to
  the verdict when `can_close_self=false`: the verdict STATE phrase stands,
  no close OFFER appears.
- Router rows must cite each sink's REAL entry point as documented in that
  sink's own SKILL.md (read each one during implementation; do not invent
  invocation parameters — the mstack-handoff no-prefill criterion is the
  template for this discipline).

Decision notes:

- The findings multiSelect labels name the finding and its destination
  ("stale README section → propose edit"), so one question carries both
  "should we act" and "where it goes".
- AskUserQuestion options cap at 4: the 1–4-findings direct question fits by
  definition; the >4 path is triage-first. "Apply all" applies each finding
  via its route, honoring propose-by-default (a proposed doc edit still
  shows the diff before writing — "apply" means "start the route", not
  "skip approval").
- Hosts without AskUserQuestion: ask the same questions as plain numbered
  prose (agent-neutral wording, per repo convention), same budget.
- Arrow 2 of the locked design — `cctrl-session-end` invoking
  `/mstack-wrap-up` as a soft dependency (probe, silently skip when mstack
  absent) — lives in the cctrl repo and is deliberately NOT part of this
  plan; note it in the skill's "Related skills" line so the seam is
  documented from this side.

Testing approach: unit-only

**Out of scope:** the `cctrl-session-end` edit (external follow-up, cctrl
repo); any new state directory or findings artifact; changes to
`wrapup-scan.sh`, `handoff.sh`, or the sink skills themselves; the user's
private global `CLAUDE.md` routing.

## Tasks

1. Convert 041's suggested-destination output into the router table with the
   seven finding-type → sink rows and per-sink invocation notes.
2. Write the write-policy rules: propose-by-default everywhere, the
   learned-patterns exception, and the "apply means start the route" rule.
3. Write the interaction-budget section: 0 / 1–4 / >4 branches, the
   triage-then-top-4 shape, button-only, never-a-third-question, and the
   plain-prose fallback for hosts without AskUserQuestion.
4. Write the ending logic: cctrl close offer (session id shown, warnings
   folded, `close-self` on yes, `can_close_self=false` → wait), no-cctrl
   handoff-save question gated on follow-on work, mid-session no-ending.
5. Wire the `mstack-handoff` route (invoke checkpoint mode; follow-on items
   travel via session context + handoff's own gathering step, no invented
   prefill parameter) and the budget-boundary wording; add the "Related
   skills" seam note about the external cctrl-session-end arrow.
6. Self-check greps (Verification) + re-read for budget contradictions:
   no path exceeds 2 findings-questions + 1 ending-question (3 total), the
   ending question never fires when a handoff route already ran, and no
   in-flow approval prompt exists for doc-edit proposals.

## Verification

Checks:
- [assert] grep -q 'mstack-learned-patterns' skills/mstack-wrap-up/SKILL.md && grep -q 'mstack-changelog' skills/mstack-wrap-up/SKILL.md && grep -q 'mstack-stash' skills/mstack-wrap-up/SKILL.md && grep -q 'mstack-plan-new' skills/mstack-wrap-up/SKILL.md — all routed sinks present
- [assert] grep -qi 'propose' skills/mstack-wrap-up/SKILL.md — propose-by-default policy stated
- [assert] grep -q 'can_close_self' skills/mstack-wrap-up/SKILL.md — close offer gated on the cctrl-status field
- [assert] grep -q 'close-self' skills/mstack-wrap-up/SKILL.md — close action delegates to handoff.sh
- [assert] grep -qi 'apply all' skills/mstack-wrap-up/SKILL.md — >4-findings triage branch present
- [assert] grep -qi 'save a handoff' skills/mstack-wrap-up/SKILL.md — no-cctrl ending question present
- [assert] grep -q 'cctrl-session-end' skills/mstack-wrap-up/SKILL.md — external arrow documented from this side
- [cmd] bash -n skills/mstack-run/scripts/*.sh — script gate still clean (no scripts should change in this plan)

<!-- mstack:seam
produced:
assumed:
- kind: symbol; name: cmd_close_self; file: skills/mstack-run/scripts/handoff.sh
- from: 041; kind: file; name: skills/mstack-wrap-up/SKILL.md; file: skills/mstack-wrap-up/SKILL.md
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | ISSUES_FOUND (outside voice) | 15 raised → 1 adopted via decision, 8 mechanical fixes, 6 rejected |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 1 issue, 0 critical gaps — folded into plan |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** adopted — post-flow doc-edit proposal apply (6A). Mechanical — budget arithmetic corrected (0–2 findings + ≤1 ending, ≤3 total), ending-question dedup vs handoff route, route ordering (handoff last), operational memory-sink detection rule, named cctrl-status contract, sink-entry-point verification discipline, 041-layering preservation, prose-fallback reply format. Rejected — allowed-tools portability (house precedent: mstack-handoff lists AskUserQuestion), "unit-only mislabel" (house taxonomy), "bash -n irrelevant" (it asserts the no-script-change invariant), "grep theater" (inherent to prose skills; logic coherence covered by Task 6 self-check).
- **CROSS-MODEL:** the budget contradiction Codex caught was real and introduced by this review pipeline itself; corrected. No unresolved tension.
- **VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS

## Implementation Notes

Layered the router + interaction layer onto 041's `skills/mstack-wrap-up/SKILL.md`,
preserving its wording, structure, and flow order (recall → scan → merge →
findings questions → routes → verdict → ending) rather than rewriting it. Added
the locked seven-row router table with each sink's REAL entry point verified
against that sink's own SKILL.md (`learnings.sh append '<json>'`, `mstack-changelog`
no-arg, `mstack-stash "quoted string"`, `mstack-plan-new "<title>"`, and
`mstack-handoff` in checkpoint mode with NO prefill API — none exists); the
propose-by-default write policy with `mstack-learned-patterns` stated as the single
exception; the non-blocking doc-edit proposal rule (ready diff in the report,
applied later on the user's word, zero in-flow approval prompts); the 0–2
findings-questions + ≤1 ending-question budget (0 / 1–4 multiSelect / >4
triage-then-top-4, never a third findings question, numbered-prose fallback for
hosts without AskUserQuestion); route ordering with the handoff last; the cctrl
close offer gated purely on `available=true` AND `can_close_self=true`; the
no-cctrl handoff-save ending gated on follow-on work; mid-session no-ending; and
the "Related skills" seam note for the external `cctrl-session-end` arrow.
`allowed-tools` extended with AskUserQuestion, Skill, Write. No scripts were
touched (asserted by a verification check).

**One interpretation call, recorded because it resolves a real contradiction in
the plan's own text.** The plan says both "the `mstack-handoff` route runs LAST
and wrap-up asks NOTHING after the transfer" and "the close offer fires after the
verdict" — which cannot both hold when a handoff route was selected. Resolved by
making a routed handoff BE the ending: it runs after the verdict in place of any
ending question. The handoff-save question is skipped because the handoff already
happened (the plan's own dedup criterion), and the close offer is skipped because
wrap-up asks nothing after transferring interaction control — and `mstack-handoff`'s
own cctrl mode already covers closing. This generalizes the plan's dedup criterion
from "skip the handoff-save question" to "skip the ending question", which is the
only coherent reading of the "asks NOTHING after the transfer" clause.

**Files changed:**

- `skills/mstack-wrap-up/SKILL.md` (modified)

**Commit:** `4fb3e8d` — `feat(mstack-wrap-up): router + interaction layer — sinks, budget, close offer`
