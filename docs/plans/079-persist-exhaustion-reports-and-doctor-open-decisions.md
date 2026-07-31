---
id: 079
title: persist investigation exhaustion reports and doctor open decisions
status: skipped
blocked-by: [074]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "backlog optimization: observability for a report that already exists in the transcript; no status transition by its own AC"
---

## Requirements

Two reasoning artifacts currently evaporate with the session. (a)
mstack-investigate's structured INVESTIGATION EXHAUSTED report
(`skills/mstack-investigate/SKILL.md:145-165`: symptom, all 9 hypotheses with
why-failed, diagnosis, human suggestion) is printed to the transcript only;
the plan gets a one-line `failed-reason` (mstack-run Step 7b,
`skills/mstack-run/SKILL.md:1084-1085`). A later human — or a plan-074 retry —
re-tests the same 9 hypotheses from scratch. (b) plan-doctor's convergence
residuals (3-round cap → forced `needs-fixes` with residuals logged to chat
only, `skills/mstack-plan-doctor/SKILL.md:1226-1229`) and its "user
challenges" (the pending architect decision, plan-doctor SKILL.md:581-584)
are lost if nobody is watching the terminal.

**Acceptance criteria**

- [ ] On exhaustion, the full report is written to
      `.mstack/evidence/plan-<id>/investigation.md` — the established
      per-plan evidence sink (`skills/mstack-run/references/verification-spec.md:29,83-108`).
- [ ] The plan's `failed-reason:` references that path (machine identifier,
      bare path per the Plan Citation Convention exemption in `AGENTS.md`).
- [ ] mstack-investigate's mandatory reflection block
      (mstack-investigate SKILL.md:45-47) must name eliminated hypotheses
      from the persisted ledger when one exists, making silent
      category-relabeling visible across retries.
- [ ] Doctor's convergence residuals and pending user challenges are written
      into the plan file itself: an `## Open Decisions` section plus a
      precise `blocked-reason:`, so any later session or notification can
      surface the exact pending decision without re-derivation.
- [ ] Neither write touches review state (`reviews:`, `review-required`,
      `needs-review` clearing) or any status transition beyond what the
      existing paths already perform.

## Design

(a) The write happens where the report is produced: mstack-investigate's
exhaustion step gains "write the same block to
`.mstack/evidence/plan-<id>/investigation.md`" (mkdir -p first, same idiom as
verification-spec.md:29) before returning verdict FAILED; mstack-run Step 7b
then sets `failed-reason: investigation-exhausted (see
.mstack/evidence/plan-<id>/investigation.md)`. The bare machine token comes
first deliberately: plan 074's `failure_class` matches the first
whitespace-delimited token, so this composite value classifies as
`investigation-exhausted` → permanent (074's table), not as unknown. `.mstack/` is gitignored, so
this is a per-machine artifact — acceptable because it is evidence for a
local retry/human, referenced by path, not durable project knowledge.
"Hypothesis X was tested via Y and disproven by Z" is a fact, compatible with
checkpoint's facts-not-reasoning doctrine (mstack-run SKILL.md:1153-1169) —
but it goes to evidence/, NOT checkpoint: checkpoint stays a compact resume
record, the ledger is bulk evidence. On a subsequent investigation of the
same plan, Phase 1 reads the ledger if present and the reflection block cites
which prior hypotheses are already eliminated.

(b) The committed plan file is the correct sink for doctor's open decisions —
explicitly NOT plan 052's findings-log: 052's Design forbids durable
knowledge in that cache ("Nothing that is not reconstructible may be stored
here", `docs/plans/052-carry-findings-forward-between-phases.md:39-43`), and
a pending architect decision is not reconstructible by re-deriving. Doctor's
Step 4b cap path and user-challenge path append/update an `## Open Decisions`
section (one bullet per residual/challenge: what is pending, the options, who
decides) and set `blocked-reason:` to a one-line pointer at that section.
Plan files are committed, so the decision survives sessions and machines.
Note the deliberate asymmetry: neither doctor path sets `status: blocked`
today and this plan adds no status transition (AC 5), so `blocked-reason:`
here is an informational pointer on a possibly-still-pending plan — it makes
the open decision legible to status/notification surfaces without changing
pickability. It cannot be auto-cleared by plan 075's heal.sh, whose match
pattern is strictly `dependency failed (...)`. Doctor's own structural
validation does not choke on the extra section: its section rules error only
on MISSING required sections (plan-doctor SKILL.md:761-770), and the
template comment added by Task 4 documents `## Open Decisions` as
tool-written, like Implementation Notes.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-investigate/SKILL.md`: write the exhaustion report to the
  evidence dir; reflection reads the persisted ledger.
- `skills/mstack-run/SKILL.md`: Step 7b `failed-reason` path reference;
  references/subagent-prompt.md if the condensed prompt embeds the
  exhaustion behavior.
- `skills/mstack-plan-doctor/SKILL.md`: cap path (1226-1229) and
  user-challenge path (581-584) write `## Open Decisions` +
  `blocked-reason:`.
- `skills/mstack-run/plan-template.md`: note `## Open Decisions` as a
  doctor-written section (comment, like Implementation Notes).
- `AGENTS.md`: one paragraph on the two sinks and why 052's cache is not one.

**Out of scope:** committing anything under `.mstack/`; changing the strike
rule or the 3-round cap themselves; checkpoint schema changes; plan 052's
findings-log (different artifact, reconstructible-only).

## Tasks

1. Add the evidence-write step to mstack-investigate's exhaustion path and
   the ledger-aware reflection requirement.
2. Point Step 7b's `failed-reason` at the evidence path.
3. Add the `## Open Decisions` writes to plan-doctor's cap and
   user-challenge paths, with `blocked-reason:` pointers.
4. Update `plan-template.md` comment block and `AGENTS.md`.
5. Run the smoke set.

## Verification

Checks:

- [cmd] `grep -q "evidence/plan-" skills/mstack-investigate/SKILL.md`
- [cmd] `grep -q "investigation.md" skills/mstack-run/SKILL.md`
- [assert] `grep -c "Open Decisions" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q "Open Decisions" skills/mstack-run/plan-template.md`
- [cmd] `grep -q "Open Decisions" AGENTS.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/wrapup-scan-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/plan-ref-smoke.sh`
