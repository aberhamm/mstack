---
id: 070
title: Frontmatter vocabulary alignment
status: pending
blocked-by: [058]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

The audit found drift between the frontmatter vocabularies mstack DECLARES
(plan-template, plan-doctor's checks) and the values its skills actually
WRITE. Concretely: `mstack-backlog` writes `status: skipped` (SKILL.md lines
167, 181) but `mstack-plan-doctor` line 749 and `plan-template.md` line 13
declare a closed status set without it, and mstack-run's backlog tally (lines
463-465) ignores it while Step 8 (lines 1218-1221) counts it.
`verification-spec.md` lines 136-138 instruct writing `qa: automated,verified`
— out of vocabulary versus the template (line 34), doctor (line 757), and Step
7a (line 945), which all say `none|automated|e2e|browser`. Doctor demands a
phantom `[e2e]` check type in four places, omits `code` from its needs-review
vocabulary, and AGENTS.md line 65 claims authoring stamps `review-required`
when neither authoring skill does. Each mismatch makes some honest writer or
validator wrong.

**Acceptance criteria**

- [ ] `status: skipped` is LEGALIZED: added to plan-template.md line 13's
      comment and doctor's status vocabulary (line 749), with defined
      semantics — the picker ignores skipped plans, the doctor does not error
      on them, and a plan whose `blocked-by` includes a skipped plan gets a
      named diagnostic FROM THE DOCTOR (not a generic missing-dependency
      error). The picker stays mechanical — a skipped dependency simply never
      reads as `done`, no picker code changes (per Design).
- [ ] `qa:` vocabulary is unified on the template's existing values:
      verification-spec.md lines 136-138 drop `automated,verified` and align
      to `none|automated|e2e|browser` (no new value is introduced).
- [ ] Doctor's four `[e2e]` mentions (lines 430, 444, 449, ~549) are rewritten
      to "`[browse]` or an E2E-runner `[cmd]` check", matching the executable
      grammar everywhere else (verification-spec lines 9-13, subagent-prompt
      lines 92-97, verify-lint.sh lines 146/149: `cmd|assert|status|browse|manual`).
- [ ] Doctor's needs-review vocabulary (line 753: "none, eng, design, ceo")
      adds `code`, which mstack-run (lines 874-879) and AGENTS.md now write;
      doctor Step 5 gains a `code` branch: not auto-runnable, instruct
      re-running `/mstack-code-review` (mirroring mstack-run's own wording).
- [ ] `review-required` stamping at authoring becomes true: mstack-plan-new
      Step 4/4a (lines 85-98) and mstack-plan-multi's frontmatter spec (lines
      278-286) both stamp `review-required: <set>` matching the assigned
      reviews (051-style: `needs-review: none` + `review-required: <set>`, or
      needs-review set when review must precede pickup), and the template's
      commented line 19 is updated to say authoring skills stamp it.
- [ ] The `[status]` separator is declared once as accepting both `->`
      (verification-spec line 11) and `→` (line 38) — one sentence, both forms
      legal, instead of two contradictory definitions.
- [ ] Doctor Step 5 line 1310 "If no, print the list and exit" becomes
      "proceed to Step 6" so Steps 5b/6 still run.

## Design

Prose-only alignment; no script behavior changes (the picker already skips
non-pending statuses mechanically — this plan documents semantics, it does not
add picker code). Where a vocabulary and a writer disagree, the resolution
rule is: prefer the value already persisted in real repos (`skipped` exists in
the wild → legalize) and prefer the smaller declared set where nothing
persists the extra value (`automated,verified` was never a template value →
drop it). Verify each cited line/quote against the working tree before
editing; this plan is blocked on 058, which may shift line numbers — re-locate
by quoted text, not line number.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/plan-template.md`: status comment, review-required comment
- `skills/mstack-plan-doctor/SKILL.md`: status/needs-review vocabularies,
  `[e2e]` rewrites, Step 5 code branch, Step 5 exit wording
- `skills/mstack-run/SKILL.md`: tally line includes skipped (lines 463-465)
- `skills/mstack-run/references/verification-spec.md`: qa values, separator
- `skills/mstack-plan-new/SKILL.md`: stamp review-required
- `skills/mstack-plan-multi/SKILL.md`: stamp review-required

**Out of scope:** changing `review-gate.sh` (its derivation rules already
handle absent `review-required`); adding new qa or status values beyond
legalizing `skipped`; renaming `skipped` to anything else; editing
mstack-backlog's write sites (they become correct by legalization).

## Tasks

1. Legalize `skipped` in template + doctor, define picker/doctor/dependency
   semantics, and add it to mstack-run's tally line.
2. Align verification-spec's qa instruction to the canonical value set.
3. Rewrite doctor's four `[e2e]` mentions to `[browse]`/E2E-runner-`[cmd]`.
4. Add `code` to doctor's needs-review vocabulary plus the Step 5 branch.
5. Make mstack-plan-new and mstack-plan-multi stamp `review-required`; update
   the template comment to match AGENTS.md's "stamped once at authoring".
6. Declare the `->`/`→` separator equivalence once; fix doctor line 1310 to
   proceed to Step 6.

## Verification

Checks:

- [cmd] `grep -q 'skipped' skills/mstack-run/plan-template.md`
- [cmd] `grep -q 'skipped' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `! grep -n 'automated,verified' skills/mstack-run/references/verification-spec.md`
- [cmd] `! grep -n '\[e2e\]' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q 'none, eng, design, ceo, code' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q 'review-required' skills/mstack-plan-new/SKILL.md`
- [cmd] `grep -q 'review-required' skills/mstack-plan-multi/SKILL.md`
- [cmd] `! grep -n 'If no, print the list and exit' skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q 'proceed to Step 6' skills/mstack-plan-doctor/SKILL.md`
