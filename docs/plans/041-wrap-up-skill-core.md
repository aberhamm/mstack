---
id: 041
title: mstack-wrap-up skill core — modes, recall pass, delegated scan, verdict, guardrails
status: in-progress
blocked-by: [040]
priority:
goal: wrap-up-skill
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-14
reviews:
  - type=eng verdict=approved date=2026-07-14 by=mstack-review
---

## Requirements

Codify the standing end-of-session practice — before a session ends, ask it
for cleanup opportunities and documentation/knowledge updates *while its
context still exists* — as a new portable skill, `skills/mstack-wrap-up/`.
Today this practice is codified nowhere: `mstack-handoff` harvests context
*for the next session* (continuation); nothing harvests context *for the
repository* (terminal). The design was locked in the 2026-07-13
wrap-up-skill-design session; this plan implements the core skill. The
router-to-sinks and interaction layer land in plan 042 — until then the skill
reports findings inline (report-only) and renders its verdict.

**Acceptance criteria:**

- [ ] New `skills/mstack-wrap-up/SKILL.md` with frontmatter matching the
      `mstack-plan-doctor` house shape (`name`, block-scalar `description`,
      `triggers` list, `allowed-tools` block), name `mstack-wrap-up`
      (deliberately NOT "session-end" — avoids collision with the external
      `cctrl-session-end` skill). `allowed-tools` must include `Agent` (the
      Pass B subagent delegation fails without it — plan-doctor's block at
      `skills/mstack-plan-doctor/SKILL.md:16-23` is the precedent: Bash,
      Read, Edit, Glob, Grep, Skill, Agent). Set it to at least: Bash, Read,
      Glob, Grep, Agent. Plan 042 extends this same block with its
      interaction/routing tools; do not pre-add tools 041 doesn't use.
- [ ] **Three-role doctrine stated up front:** `mstack-wrap-up` = the harvest
      and front door/conductor; `mstack-handoff` = continuation (offered when
      follow-on work exists); `cctrl-session-end` = the close (external).
      Terminal-vs-continuation is the axis.
- [ ] **Verdict, not close:** the skill's product is
      `✅ cleared to close` or `⚠️ not cleared` + concrete reasons. Verdict is
      honest but NEVER blocking — no gate semantics, no interference with the
      plan 034–039 enforcement family or a fleet-manager close gate. Without
      cctrl the verdict IS the ending: the word "close" never appears as an
      action. The skill inherits `mstack-handoff`'s cctrl-status doctrine
      verbatim: probe `handoff.sh cctrl-status` (resolved via the standard
      four-path skill-base loop); `available=false` → never mention cctrl,
      closing, or spawning anywhere in the flow.
- [ ] **Two passes, recall first:** Pass A = session recall, inline, FIRST —
      the skill prompts itself through five session-only-knowledge categories:
      (1) scaffolding created that should now be deleted, (2) things obsoleted
      but not deleted, (3) docs/comments the session's changes made wrong,
      (4) learnings worth persisting that were never written down,
      (5) user decisions made this session that a future session might
      re-litigate. Pass B = the mechanical scan, DELEGATED to a subagent that
      runs `wrapup-scan.sh` (plan 040) and returns the RAW structured
      findings (plus mechanical annotations only, e.g. which pattern
      matched). Classification — litter vs deliberate vs unknown — is done
      by the MAIN agent when merging with Pass A, because only the main
      agent has the session memory that distinguishes "I created this
      scaffolding an hour ago" from "user's deliberate file". The skill
      text states the priority explicitly: recall is the product; the greps
      are the floor.
- [ ] **Mid-session mode:** when invoked mid-session ("harvest, keep
      working"), the same two passes run but the verdict ending is skipped
      and no ending questions are asked.
- [ ] **Guardrails section** (verbatim commitments, each stated as a rule):
      never `git add .` — explicit file lists with explicit approval only;
      report unpushed commits but NEVER push; NEVER touch plan `status`,
      `needs-review`, `review-required`, or `reviews` (plan-035 doctrine — at
      most report "plan NNN looks near-complete"); multi-repo sessions need
      an explicit repo list or detect-from-touched-paths, and the output
      SAYS which repos were checked; non-git targets (e.g. `~/inference`)
      fail LOUD — "mechanical check unavailable, recall list only" — never
      "clean"; doc writes are propose-by-default.
- [ ] Clean session ends in ~3 lines and zero questions (this plan is
      report-only, so it asks nothing at all; the 0–2 question budget
      machinery arrives in 042). The compact empty state is SPECIFIED:
      recall categories with nothing collapse to a single line ("Recall:
      nothing in any category"), the scan line reports "scan: clean
      (<repo>)", and the verdict closes — five empty category paragraphs
      is a spec violation, not thoroughness.
- [ ] **"close" — state vs action, disambiguated in the skill text:** the
      verdict phrase "cleared to close" is a STATE assessment and is always
      allowed (with or without cctrl). What `available=false` forbids is
      "close" as an offered ACTION (an offer, question, or command to close
      the session). The self-check in Tasks enforces exactly this split.
- [ ] Report-only boundary stated: the write-facing guardrails (propose-by-
      default doc edits, approval rules) are forward-doctrine for 042 —
      written now so the text is complete, inert in 041 because this layer
      routes nothing and its tool list omits Edit/Write.
- [ ] 041's report-only state is transitional within the wrap-up-skill goal
      batch (042 lands immediately after); the skill text notes findings are
      re-derivable by re-running wrap-up, so nothing is lost if the session
      closes before 042 exists.
- [ ] **Registration:** new routing rows in `AGENTS.md` Skill Routing
      ("wrap up the session", "end-of-session review", "harvest this
      session before we close" → `mstack-wrap-up`) WITH disambiguating
      non-examples, since neighboring skills own adjacent phrases: "wrap
      this up for now / come back to this" stays `mstack-stash`, "handoff /
      save session state" stays `mstack-handoff` — the routing row states
      the terminal-vs-continuation axis so "wrap up" alone doesn't steal
      continuation requests. Linking: do NOT
      rely on `./setup` for this checkout — `setup` symlinks each skill into
      the REPO'S PARENT directory (`$PARENT_DIR/$name`, i.e. `~/dev/` here),
      which is the legacy cloned-inside-a-skills-dir layout, and it has no
      dry-run mode. Instead create the same explicit symlink the sibling
      mstack-* skills already use:
      `ln -s "$REPO_ROOT/skills/mstack-wrap-up" ~/.config/skillshare/skills/mstack-wrap-up`
      (skipping if it already exists), then verify it resolves.

## Design

One new prose skill + one routing edit. Follow the structure conventions of
`skills/mstack-handoff/SKILL.md` (helper resolution block first, mode
detection early, numbered flow, "What NOT to do" section at the end).

**Files expected to change:**

- `skills/mstack-wrap-up/SKILL.md`: new — the whole skill.
- `AGENTS.md`: add routing rows to the Skill Routing list.

Skill flow skeleton (terminal mode): resolve helpers → probe
`handoff.sh cctrl-status` silently → Pass A recall (inline, structured under
the five categories, with an explicit instruction to say "nothing in this
category" rather than skipping) → Pass B: spawn one subagent that runs
`wrapup-scan.sh` for each in-scope repo and returns interpreted findings
(litter vs deliberate) → merge into one findings list (each finding: what,
where, suggested destination — destinations become live routes in 042; in
this plan they are printed as suggestions) → render the verdict block →
stop. Mid-session mode: same through the findings list, then "continuing —
harvest recorded" instead of a verdict.

Edge cases the skill text must handle:

- cctrl `available=true` but `can_close_self=false`: the session is not
  closable from within (`handoff.sh` merely mirrors cctrl's `.can_close_self`
  field and defaults false — fleet-managed sessions are one example, not the
  defined semantics; gate purely on the field). Render verdict and wait; no
  close offer exists in this plan at all (042 adds it), but the doctrine
  line is written now so 042 slots in.
- Non-git working directory: Pass B reports the loud unavailable message and
  the output is recall-only, labeled as such.
- Multi-repo: EXPLICIT scope only. Default = the repo of `$PWD`; additional
  repos are scanned only when named in the invocation, or when the main
  agent is CERTAIN from its own session memory that it edited them (never
  inferred by the subagent — no durable touched-path log exists). The
  findings header lists exactly which repos were scanned; repos the recall
  pass merely suspects are surfaced as report-only mentions, not scanned
  silently.

Testing approach: unit-only

**Out of scope:** the router-to-sinks table, AskUserQuestion budget, close
offer, and no-cctrl handoff-save question (all plan 042); any edit to
`cctrl-session-end` (external follow-up in the cctrl repo); any edit to the
user's private global `CLAUDE.md` routing (manual follow-up); changes to
`handoff.sh` or `wrapup-scan.sh`.

## Tasks

1. Draft `skills/mstack-wrap-up/SKILL.md` frontmatter + three-role doctrine +
   mode detection (terminal default; mid-session when the invocation says
   "keep working"/"mid-session"/similar).
2. Write the cctrl-status probe section, copying `mstack-handoff`'s
   silent-degrade wording (`available=false` → the user is none the wiser).
3. Write Pass A: the five recall categories with per-category prompts and the
   "recall is the product" framing.
4. Write Pass B: subagent delegation prompt that runs `wrapup-scan.sh`
   (four-path resolution) and returns raw findings + mechanical
   annotations; classification stays with the main agent.
5. Write the findings merge (main-agent litter/deliberate/unknown
   classification) + report-only output format incl. the compact empty
   state, and the verdict block (cleared / not-cleared + reasons),
   including the mid-session variant and the guardrails section.
6. Add the `AGENTS.md` routing rows; create the
   `~/.config/skillshare/skills/mstack-wrap-up` symlink explicitly (matching
   the sibling mstack-* links; do not run `./setup` for this) and verify it
   resolves to the repo skill dir.
7. Self-check: every locked-design keyword greps in the file (see
   Verification), and "close" as an offered ACTION appears only inside
   cctrl-gated text (the verdict's "cleared to close" STATE phrase is
   exempt, per the state-vs-action criterion).

## Verification

Checks:
- [cmd] test -f skills/mstack-wrap-up/SKILL.md
- [assert] head -3 skills/mstack-wrap-up/SKILL.md | grep -q 'name: mstack-wrap-up' — frontmatter name is correct
- [assert] grep -q 'cleared to close' skills/mstack-wrap-up/SKILL.md — verdict vocabulary present
- [assert] grep -q 'cctrl-status' skills/mstack-wrap-up/SKILL.md — probe wired to handoff.sh
- [assert] grep -q 'wrapup-scan.sh' skills/mstack-wrap-up/SKILL.md — Pass B delegates to the plan-040 script
- [assert] grep -qi 'never .git add \.' skills/mstack-wrap-up/SKILL.md — git add guardrail stated
- [assert] grep -qi 'never push' skills/mstack-wrap-up/SKILL.md — push guardrail stated
- [assert] grep -q 'review-required' skills/mstack-wrap-up/SKILL.md — plan-review-state guardrail names the protected fields
- [assert] grep -q 'mstack-wrap-up' AGENTS.md — routing row added
- [cmd] test "$(readlink "$HOME/.config/skillshare/skills/mstack-wrap-up")" = "$(git rev-parse --show-toplevel)/skills/mstack-wrap-up" — symlink exists AND resolves to THIS repo's skill dir (a stale or wrong-target link fails)
- [assert] grep -c 'nothing in this category\|nothing in any category' skills/mstack-wrap-up/SKILL.md | grep -qv '^0' — explicit empty-state wording present
- [assert] grep -q 'scaffolding' skills/mstack-wrap-up/SKILL.md && grep -q 're-litigate' skills/mstack-wrap-up/SKILL.md — recall categories 1 and 5 anchored (not just the count)
- [assert] awk '/^---$/{n++; if(n==2) exit} n' skills/mstack-wrap-up/SKILL.md | grep -A8 'allowed-tools' | grep -q 'Agent' — frontmatter allowed-tools includes Agent for Pass B delegation

<!-- mstack:seam
produced:
- kind: file; name: skills/mstack-wrap-up/SKILL.md; file: skills/mstack-wrap-up/SKILL.md
assumed:
- kind: symbol; name: cmd_cctrl_status; file: skills/mstack-run/scripts/handoff.sh
- from: 040; kind: file; name: skills/mstack-run/scripts/wrapup-scan.sh; file: skills/mstack-run/scripts/wrapup-scan.sh
-->

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | ISSUES_FOUND (outside voice) | 11 raised → 2 adopted via decisions, 6 mechanical fixes, 3 rejected |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 2 issues, 0 critical gaps — all folded into plan |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** adopted — main-agent classification of scan findings (4A), explicit-only multi-repo scope (5A); mechanical — compact empty-state spec, state-vs-action "close" disambiguation, routing non-examples, symlink-target verification, forward-doctrine note on write guardrails. Rejected — "cctrl probe is dead weight" (deliberate 042 scaffolding), "persist an artifact in 041" (findings re-derivable; 042 lands in same batch), "drop the report-only layer".
- **CROSS-MODEL:** no unresolved tension; both reviewers agree the core skill is implementable as specified.
- **VERDICT:** ENG CLEARED — ready to implement.

NO UNRESOLVED DECISIONS
