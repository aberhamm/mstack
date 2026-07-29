---
id: 051
title: add a review autonomy setting so backlog clearing is not interactive
status: pending
blocked-by: []
priority:
goal: pipeline-hardening
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
---

## Requirements

`plan-eng-review` hard-codes one AskUserQuestion per finding plus a STOP after
each of its four sections. That is right when shaping something and is the main
tax when clearing a backlog.

Measured across one session: the interactive first two reviews versus the
batched last two showed a **~3x time difference with nil quality difference**.
The batched mode was adopted mid-session on instruction and nothing got worse.

**Acceptance criteria**

- [ ] `review.autonomy` in `.mstack/config.json` accepts exactly
      `interactive | batched | auto`.
- [ ] `interactive` (default) preserves today's behavior **byte for byte** — a
      user who sets nothing sees no change.
- [ ] `batched` presents all of a section's findings in one decision point.
- [ ] `auto` decides using stated principles and **reports every decision it
      made**, with enough detail to reverse any one of them.
- [ ] Unknown or malformed values fall back to `interactive` with a warning —
      the most conservative mode, never the most autonomous. A typo must not
      silently grant autonomy.
- [ ] `auto` never self-clears a review gate. Recording a verdict stays with the
      named review skills (plan 035); this setting governs how findings are
      *presented*, never who may approve.

## Design

The reach limit must be stated plainly rather than discovered later:
`plan-eng-review` is a **gstack** skill outside this repo. mstack can set this
key and honor it in **mstack's own** review paths (`mstack-plan-doctor` Step 5
orchestration, `mstack-code-review`), but it cannot change gstack's interaction
policy. Full effect on `plan-eng-review` needs an upstream change there.

So this plan delivers: the config key, the semantics, mstack-side enforcement,
and a documented contract gstack can adopt. It does **not** claim to make
`plan-eng-review` batched.

`auto` reuses the decision principles already written in plan-doctor's built-in
auto-decision framework (mechanical / taste / user-challenge). A
**user-challenge** class decision is never auto-decided even under `auto` —
scope changes, architectural bets, and anything one-way still stop and ask.

**Files expected to change:**

- `skills/mstack-run/scripts/config.sh`: validate and expose `review.autonomy`.
- `skills/mstack-plan-doctor/SKILL.md`: honor it in Step 5 orchestration.
- `skills/mstack-code-review/SKILL.md`: honor it.
- `skills/mstack-run/scripts/config-smoke.sh`: new or extended; covers the
  invalid-value fallback.
- `AGENTS.md`: document the three modes and the gstack reach limit.

**Out of scope:** modifying gstack skills; auto-deciding user-challenge
decisions; anything that records or clears a review verdict.

## Tasks

1. Add validation and a defaulting accessor to `config.sh`.
2. Honor the mode in plan-doctor Step 5 and mstack-code-review.
3. Smoke-test the three modes plus the invalid-value fallback.
4. Document the modes and the reach limit.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/config.sh show`
- [cmd] `grep -q "review.autonomy" skills/mstack-run/scripts/config.sh`
- [cmd] `grep -q "review.autonomy" AGENTS.md`
- [assert] `grep -c "interactive" skills/mstack-run/scripts/config.sh`
- [manual] confirm an invalid value warns and falls back to interactive
