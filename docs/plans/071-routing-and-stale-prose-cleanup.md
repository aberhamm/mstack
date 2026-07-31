---
id: 071
title: Routing and stale-prose cleanup
status: skipped
blocked-by: []
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "folded into 069 — both prose-only sweeps over skill files, no scripts, no execution risk"
---

## Requirements

A sweep of stale, colliding, or misleading prose across the skill suite. Each
item is small; together they misroute requests ("review the backlog" triggers
two different skills), advertise dead paths (a deprecated skill that still
carries a 193-line operational body with its own hand-rolled gate), and leave
instructions pointing at layouts this repo abandoned (`plans/` paths,
branch/PR-era template comments, a hardcoded `docs/plans/` commit trailer).

**Acceptance criteria**

- [ ] Trigger collision resolved: "review the backlog" appears in BOTH
      mstack-plan-doctor's triggers (SKILL.md line 12) and mstack-backlog's
      (line 10); AGENTS.md line 37 routes it to backlog — the trigger is
      removed from doctor's list.
- [ ] mstack-plan-multi line 347 (**"Never suggest 'all pending mstack plans
      are done or failed.'"**) no longer reads as prohibiting the framework's
      flagship command (README line 41 presents it as canonical) — reworded to
      scope the rule to plan-multi's own summary output: always suggest the
      goal-scoped form there.
- [ ] mstack-simplify-code/SKILL.md: the description says DEPRECATED/redirect
      but the 193-line body is a fully operational legacy flow — the body is
      replaced with a ~3-line redirect stub pointing to mstack-code-review
      Step 4b.
- [ ] mstack-status "Update check" section (lines 65-77) is deleted: it probes
      `~/.config/skillshare/skills/mstack/bin`, a path that doesn't exist in
      skillshare installs (skills install as separate `mstack-*` dirs), no-ops
      silently via `|| true`, and the Auto-init section (lines 29-38) already
      runs `bin/mstack-update-check`.
- [ ] references/CONVENTION.md is refreshed: its Inventory table lists only
      mstack-run's 8 references while mstack-plan-doctor ships five
      (adversarial-audit, frame-review, seam-contracts, testing-audit,
      trap-resistance) that are uninventoried; the 4-path SKILL_DIR resolution
      idiom (skillshare → agents → codex → claude) is blessed as THE idiom and
      competing variants in skill files are noted for convergence.
- [ ] mstack-wrap-up lines 598-603 reference `PRE_DIRTY`/`MODIFIED` sets that
      exist only inside an mstack-run iteration — reworded to session-recall
      language (edits the user had before the session vs. edits this session
      made) with no dependence on mstack-run's variables.
- [ ] plan-template.md line 3 ("Copy this into `plans/NNN-slug.md`") says
      `docs/plans/` (preferred) with `plans/` fallback; line 12 ("becomes
      branch name and PR title") drops the branch/PR claim (no branches/PRs in
      this workflow). mstack-plan-new lines 77 and 127 (`plans/NNN-slug.md`)
      become `$PLANS_DIR/NNN-slug.md`.
- [ ] The commit trailer at mstack-run SKILL.md line 984
      (`Refs: docs/plans/<file>`) becomes `Refs: <plans-dir>/<file>` so
      plans/-rooted repos get a correct trailer.
- [ ] mstack-changelog line 20 ("You are running the `/changelog` skill")
      names itself `/mstack-changelog`.
- [ ] mstack-stash save numbering (lines 70-73) derives `NEXT_NUM` from file
      COUNT, which collides after a delete (files are never renumbered per
      lines 138-139) — derived instead from the max existing numeric prefix +1.
- [ ] mstack-stash and mstack-handoff descriptions each gain a one-line "not
      this skill if..." cross-reference on the terminal-vs-continuation axis
      (today that disambiguation lives only in AGENTS.md and wrap-up).

## Design

Independent one-site edits; no shared state between items, so they can be
executed in any order. For the simplify-code stub, keep frontmatter (name,
description, argument-hint) intact so routing still resolves, and make the
body: deprecated notice, pointer to `/mstack-code-review` Step 4b, nothing
else. For the stash numbering fix, the max-prefix derivation is
`ls "$STASH_DIR" | grep -oE '^[0-9]+' | sort -n | tail -1` + 1 (or 1 when
empty). Verify each cited line/quote against the working tree before editing;
re-locate by quoted text if lines shifted.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: drop trigger
- `skills/mstack-plan-multi/SKILL.md`: rescope the never-suggest rule
- `skills/mstack-simplify-code/SKILL.md`: body → redirect stub
- `skills/mstack-status/SKILL.md`: delete Update check section
- `skills/mstack-run/references/CONVENTION.md`: inventory + idiom refresh
- `skills/mstack-wrap-up/SKILL.md`: session-recall rewording
- `skills/mstack-run/plan-template.md`: lines 3 and 12
- `skills/mstack-plan-new/SKILL.md`: `$PLANS_DIR` phrasing
- `skills/mstack-run/SKILL.md`: Refs trailer
- `skills/mstack-changelog/SKILL.md`: self-name
- `skills/mstack-stash/SKILL.md`: numbering + cross-ref
- `skills/mstack-handoff/SKILL.md`: cross-ref

**Out of scope:** deleting mstack-simplify-code entirely (kept for routing
compatibility); converging every skill's SKILL_DIR idiom in this plan
(CONVENTION.md blesses the idiom; migration is follow-up work); renumbering
existing stash files; any script changes.

## Tasks

1. Remove doctor's "review the backlog" trigger; rescope plan-multi line 347.
2. Replace mstack-simplify-code's body with the redirect stub.
3. Delete mstack-status's Update check section.
4. Refresh CONVENTION.md's inventory (add doctor's five references) and bless
   the 4-path resolution idiom.
5. Reword wrap-up's PRE_DIRTY/MODIFIED passage to session-recall language.
6. Fix template lines 3/12, plan-new `plans/` phrasing, and the Refs trailer.
7. Fix changelog self-name, stash numbering, and add the two axis cross-refs.

## Verification

Checks:

- [cmd] `! grep -n 'review the backlog' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q 'review the backlog' skills/mstack-backlog/SKILL.md`
- [cmd] `test "$(wc -l < skills/mstack-simplify-code/SKILL.md)" -lt 60`
- [cmd] `grep -q 'mstack-code-review' skills/mstack-simplify-code/SKILL.md`
- [cmd] `! grep -n 'MSTACK_BIN' skills/mstack-status/SKILL.md`
- [cmd] `grep -q 'adversarial-audit' skills/mstack-run/references/CONVENTION.md`
- [cmd] `! grep -n 'becomes branch name and PR title' skills/mstack-run/plan-template.md`
- [cmd] `! grep -n 'Refs: docs/plans/<file>' skills/mstack-run/SKILL.md`
- [cmd] `grep -q 'mstack-changelog' skills/mstack-changelog/SKILL.md`
- [cmd] `! grep -n 'wc -l' skills/mstack-stash/SKILL.md`
- [cmd] `! grep -rn 'PRE_DIRTY' skills/mstack-wrap-up/SKILL.md`
