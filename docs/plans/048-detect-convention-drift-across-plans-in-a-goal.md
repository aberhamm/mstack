---
id: 048
title: detect invented shared contracts across plans in the same goal
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

Doctor validates plans one at a time, so a defect shared by several plans is
found several times or never. Observed live: the `STABLE`/`COHERENT` token
contract was **invented independently by three plans, with no producer plan
committing to emit it**. Every consumer assumed a producer existed. Each plan
was individually valid; the set was incoherent.

The existing seam-check (plans 028/029) does not catch this. It diffs
`blocked-by` edges — PRODUCED versus ASSUMED across a declared dependency. Here
there is no edge to diff: the plans are siblings under one `goal:`, none
declares the other as a dependency, and the shared token appears only as prose.
The gap is structural, not a bug in seam-check.

**Acceptance criteria**

- [ ] For plans sharing a `goal:`, identify literal tokens (SCREAMING_SNAKE
      identifiers, quoted status strings, enum-like values) that appear in 2+
      plans.
- [ ] For each, determine whether any plan **commits to producing it** — names
      it in `**Files expected to change:**` context or an `mstack:seam` PRODUCED
      entry — versus only consuming/asserting it.
- [ ] Consumed-by-2+-with-no-producer is reported as a finding naming the token
      and every plan referencing it.
- [ ] **Reported, not blocking, in v1.** This is text analysis with real
      false-positive risk (a token may legitimately come from existing code, or
      from outside the goal). A noisy blocking check gets disabled, which is
      worse than a quiet reporting one.
- [ ] False-positive control: tokens already present in the committed codebase
      are excluded, since those have a real producer already.
- [ ] Smoke coverage includes a three-plan fixture reproducing the observed
      `STABLE`/`COHERENT` case.

## Design

Scope to one `goal:` at a time — that is the unit the incoherence lives in, and
it bounds the comparison to a handful of plans rather than the whole backlog.

Token extraction is deliberately narrow to keep precision up: `[A-Z][A-Z0-9_]{3,}`
plus backtick-quoted short literals. Prose words in caps (`IMPORTANT`, `NOTE`,
`TODO`) are stoplisted.

Producer detection is the weak point and must be honest about it: absent an
`mstack:seam` PRODUCED block, "commits to producing" is inferred from proximity
to a file-change entry. Where inference is unsafe, report UNKNOWN-PRODUCER
rather than asserting there is none.

**Files expected to change:**

- `skills/mstack-run/scripts/goal-coherence.sh`: new; `check <goal>` reports
  tokens consumed by 2+ plans with no committed producer.
- `skills/mstack-run/scripts/goal-coherence-smoke.sh`: new; includes the
  three-plan `STABLE`/`COHERENT` fixture and a false-positive fixture (token
  already in the codebase → not reported).
- `skills/mstack-plan-doctor/SKILL.md`: run it once per goal in all-plans scope.

**Out of scope:** blocking on findings (v1 reports); cross-goal analysis;
auto-authoring a producer plan; replacing or altering seam-check, which owns the
dependency-edge case and stays as is.

## Tasks

1. Write `goal-coherence.sh`: group by `goal:`, extract tokens, classify
   producer/consumer, exclude tokens already in the codebase.
2. Write the smoke suite with both the reproduction and the false-positive
   fixture.
3. Wire into plan-doctor as a per-goal reporting step.

## Verification

Checks:

- [cmd] `test -f skills/mstack-run/scripts/goal-coherence.sh`
- [cmd] `test -x skills/mstack-run/scripts/goal-coherence.sh`
- [cmd] `bash skills/mstack-run/scripts/goal-coherence-smoke.sh`
- [assert] `grep -c "UNKNOWN-PRODUCER" skills/mstack-run/scripts/goal-coherence.sh`
- [cmd] `grep -q "goal-coherence" skills/mstack-plan-doctor/SKILL.md`
- [manual] confirm the false-positive fixture stays silent
