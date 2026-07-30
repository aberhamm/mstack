---
id: 077
title: make plan-doctor headless-capable and auto-invoked from mstack-run blocks
status: pending
blocked-by: [pipeline-hardening:051, 073]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
---

## Requirements

The review pipeline is human-gated at four consecutive points (audit F2).
(1) Nothing auto-invokes plan-doctor: every mstack-run block message says
"Run /mstack-plan-doctor NNN" (`skills/mstack-run/SKILL.md:574` incomplete
spec, `:618` stale seam, `:707` approval-commit heal failure, `:885-893`
open review gate) — the handoff between two automated tools is a human.
(2) Doctor opens with an interactive posture prompt, Step 1b
(`skills/mstack-plan-doctor/SKILL.md:324-352`, "use AskUserQuestion when the
host provides it"). (3) Step 5 asks "Run pending reviews now?"
(plan-doctor SKILL.md:1256). (4) The dashboard asks "Commit these approvals
now?" (plan-doctor SKILL.md:216-218) — a question with NO legitimate "no",
since plan 037 ("Approved Plans Are Always Committed", `AGENTS.md`) mandates
committing recorded verdicts; Step 5's own per-review commits are already
unconditional (plan-doctor SKILL.md:1286-1295).

**Acceptance criteria**

- [ ] Config keys `doctor.posture` (`ask|expand|selective|hold|reduce`,
      mapping to Step 1b options A-D; default `ask` preserves today's
      behavior) and `doctor.run_reviews` (`always|ask`, default `ask`) in
      `config.sh`, documented in mstack-config.
- [ ] Malformed/unknown values fall back to the conservative mode (`ask`)
      with a warning — mirroring 051's rule that a typo must not silently
      grant autonomy.
- [ ] The "Commit these approvals now?" question is deleted; the plan-037
      heal commit happens unconditionally.
- [ ] A config key makes the built-in auto-decision framework
      (plan-doctor SKILL.md:86-117) selectable even when the gstack review
      skills are installed (today it activates ONLY when they are absent,
      per the discovery gate at SKILL.md:82-84).
- [ ] mstack-run, when it blocks a plan for spec/seam/review-gate reasons,
      auto-invokes plan-doctor scoped to that plan in headless mode before
      ending the iteration — exactly one attempt per plan, bounded across
      iterations by a write-ahead checkpoint marker (see Design), no loop.
- [ ] `auto`-mode limits from plan 051 are respected: user-challenge class
      decisions (plan-doctor SKILL.md:106-108) still stop and ask; nothing
      here records or clears a review verdict outside the named skills.

## Design

Align config naming with plan 051, which establishes `review.autonomy`
(`interactive|batched|auto`) and the conservative-fallback doctrine: these
keys live beside it as a `doctor.*` namespace, read via `config.sh get`
(dispatch, config.sh:124-126), validated with the same warn-and-fall-back
pattern 051 adds. Add `doctor.review_framework` (`auto|gstack|builtin`,
default `auto` = today's presence-based choice) for the built-in framework
selection. "Headless" for doctor means: posture resolved from config when
not `ask`; Step 5 runs reviews without asking when `run_reviews=always`
(review presentation interactivity is then governed by 051's
`review.autonomy`); the approvals-commit question no longer exists.

The mstack-run side edits each block site's final step: after committing the
blocked plan file, if the block reason is incomplete-spec, stale-seam, or
review-gate-open, invoke plan-doctor scoped to `${PLAN_ID}` with headless
posture (config-resolved) instead of only printing the "Run
/mstack-plan-doctor NNN" line — then end the iteration regardless of doctor's
outcome (the printed line remains as fallback when doctor is unavailable).
The invocation mechanism is the same prose skill-invocation contract
mstack-run already uses for mstack-code-review (Step 6), mstack-investigate
(Step 5 failure path), and mstack-checkpoint (Step 7c) — no new tool surface
is required.
No re-entry: mstack-run does not re-pick the same plan in this iteration, so
one doctor attempt per block is structural within an iteration. Across
iterations the bound is deterministic, not hoped-for: before invoking, write
a `doctor_autoinvoked_plan: <id>` checkpoint counter (write-ahead — a crash
mid-invoke must not buy a second attempt; checkpoint counters are the
established per-plan progress store, `skills/mstack-checkpoint/SKILL.md:98-102`).
If the marker already names this plan when a later iteration blocks it
again, skip the auto-invoke and print only the fallback "Run
/mstack-plan-doctor NNN" line — this is what prevents a
doctor-heals → re-pick → re-block → doctor-again ping-pong when doctor's fix
does not satisfy mstack-run's gate. (`blocked-by: 073` because 073 edits the
same block sites to add stuck-state notifications; this plan's auto-invoke
lands after those notify lines rather than conflicting with them.)

Reach limit, stated per 051: `plan-eng-review` is a gstack skill; its
per-finding interactivity cannot be changed from this repo. When
`run_reviews=always` routes into gstack skills they remain as interactive as
gstack makes them. Named follow-up: "gstack: honor mstack review.autonomy in
plan-*-review" (upstream, out of this repo).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/config.sh`: validate/expose the three
  `doctor.*` keys with conservative fallback.
- `skills/mstack-run/scripts/config-smoke.sh`: extend (051 creates it) with
  the new keys' invalid-value fallback cases.
- `skills/mstack-plan-doctor/SKILL.md`: Step 1b config-resolved posture;
  Step 5 `run_reviews` gate; delete the :216-218 commit question; framework
  selection honors `doctor.review_framework`.
- `skills/mstack-run/SKILL.md`: auto-invoke doctor at the block sites,
  guarded by the checkpoint marker.
- `skills/mstack-checkpoint/SKILL.md`: document the
  `doctor_autoinvoked_plan` counter.
- `skills/mstack-config/SKILL.md`: document the keys.
- `AGENTS.md`: note the gstack reach limit + named follow-up; align the
  plan-037 paragraph ("may offer to commit the healing fix") with the
  now-unconditional doctor commit.

**Out of scope:** modifying gstack skills; changing what plan 051 ships for
`review.autonomy`; auto-deciding user-challenge decisions; recording or
clearing review verdicts (plan 035); any retry loop around the auto-invoke.

## Tasks

1. Add the three `doctor.*` keys to `config.sh` with defaults and
   warn-and-fall-back validation; extend `config-smoke.sh`.
2. Rework plan-doctor Step 1b and Step 5 to read them; delete the
   approvals-commit question, keeping the unconditional commit.
3. Make the built-in framework selectable via `doctor.review_framework`.
4. Add the scoped headless doctor auto-invoke to mstack-run's
   incomplete-spec, stale-seam, and review-gate block paths, with the
   write-ahead `doctor_autoinvoked_plan` checkpoint marker (document it in
   mstack-checkpoint).
5. Document keys in mstack-config and the reach limit in `AGENTS.md`.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/config.sh skills/mstack-run/scripts/config-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/config-smoke.sh`
- [cmd] `grep -q "doctor.posture" skills/mstack-run/scripts/config.sh`
- [cmd] `grep -q "doctor.run_reviews" skills/mstack-run/scripts/config.sh`
- [assert] `grep -c "doctor.review_framework" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `! grep -q "Commit these approvals now" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q "doctor.posture" skills/mstack-config/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
