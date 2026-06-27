---
id: 026
title: Re-validate plans after auto-fix and review edits (close the doctor loop)
status: pending
blocked-by: []
priority:
goal: doctor-autonomy-hardening
allows-migrations: false
needs-review: none
created: 2026-06-26
---

## Requirements

`mstack-plan-doctor` applies auto-fixes (autonomy-readiness, testability,
verification, trap-resistance) and may apply review-driven edits, then emits a
verdict — but it never re-validates the EDITED plan. A defect introduced by a
fix survives to execution because nothing re-checks the post-edit state. The
doctor validates v1, the fixers produce v2, and v2 ships unvalidated. (Observed
in practice: a fix pass introduced a self-contradiction that the doctor —
having run on the pre-edit version — structurally could not have caught.)

The doctor must not emit a `ready` verdict for any plan it edited until a
re-validation pass over the final file state confirms the edits introduced no
NEW errors.

**Acceptance criteria:**

- [ ] plan-doctor tracks which plan files it modified during a run (auto-fix
      sections plus any review-applied edits) by CONTENT HASH, not git status
      class: capture each plan file's `shasum` at the start of Step 2 and treat a
      file whose hash changed as MODIFIED. (A git-status-class baseline is
      insufficient — a file already dirty/untracked before AND after an edit
      keeps the same porcelain status and would be missed.)
- [ ] After all edit phases, the doctor re-runs structural validation + scoring
      over EXACTLY the modified plans, not the whole backlog (no redundant work
      on untouched plans).
- [ ] The edit → re-validate loop repeats until a round makes no edits, OR a
      hard cap of 3 rounds is hit.
- [ ] "Clean final re-validation" is defined explicitly as: ZERO blocking
      findings on the final file state — where blocking = structural ERRORS,
      unresolved [critical] frame findings, and (once plans 027/028 land) GENUINE
      audit findings and blocking SEAM findings. The gate is on the ABSOLUTE
      count of blocking findings being zero, not merely "no NEW errors vs the
      prior round" (a pre-existing error must not survive to `ready`).
- [ ] On hitting the cap with residual blocking findings, the plan is reported
      `needs-fixes` with the residuals listed — never silently `ready`.
- [ ] The Step 6 verdict for a modified plan is gated on a clean final
      re-validation; an unmodified plan keeps its first-pass verdict.
- [ ] The re-validation pass is logged distinctly (e.g. "Re-validated N modified
      plans: M clean, K still need fixes") so the human can see the loop ran.

## Design

This is a control-flow change in plan-doctor: insert a re-validation loop
between the edit phases and the final report. Modified-plan tracking is
deterministic — snapshot the plan-file state at the start of Step 2 and diff
after the edit phases — so the loop targets only changed files and stays cheap.

**Baseline mechanism:** at the start of Step 2, compute a CONTENT HASH of every
plan file (`shasum "$PLANS_DIR"/*.md`) into an associative baseline
(`PLAN_HASHES`, path→hash). After each edit phase, recompute hashes; any plan
whose hash differs from its baseline entry is MODIFIED. Content hashing is used
deliberately INSTEAD of `git status --porcelain`: porcelain reports only the
status class, so a plan file that is already `??`/` M` before AND after an edit
keeps the same status and would be missed — and these very plan files are
untracked during this work. `shasum` is always available; no git dependency.
The baseline is recaptured at the top of each loop round so a round only sees
the edits made since the previous round.

**Loop scope:** the re-validation pass re-runs, over the changed set ONLY: the
Step 3 per-plan structural validation, the Step 2 scoring + its embedded
auto-fixes (autonomy/testability/verification/trap), AND any targeted check that
produced a finding which triggered an edit on a modified plan — specifically the
seam-contract diff on dependency edges incident to a modified plan (plan 028)
and the adversarial audit of a modified plan (plan 027). It does NOT re-run the
whole-backlog passes wholesale (Step 2b learnings, Step 2c frame review, or the
full cross-plan consistency agent over untouched plans) — those run once on the
first pass; only the per-modified-plan slices of seam/audit checks re-run, so
the loop stays cheap while still re-confirming the finding that drove the edit.

**Two re-validation triggers, one verdict gate:** (1) the autonomous edit phase
(Step 2/Step 4 auto-fixes) feeds the bounded Step 4b loop below; (2) Step 5
review-applied edits are recomputed against the baseline after reviews complete
and run through the same per-plan re-validation before Step 6 finalizes that
plan's verdict. A plan's `ready` verdict in Step 6 is gated on its FINAL
re-validation being clean, regardless of which phase last edited it.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: capture the `PLAN_HASHES` content-hash
  baseline at the start of Step 2 (Score each plan); add "Step 4b: Re-validate
  modified plans" immediately after the Step 4 report and BEFORE the Step 5
  review section (it must sit between the literal `## Step 4: Report` block and
  `## Step 5: Run pending reviews`); wrap the auto-fix + re-validate phases in
  the 3-round loop; re-validate any plan edited during Step 5 reviews before its
  Step 6 verdict; gate the Step 6 per-plan verdict and the "ready for unattended
  execution" summary on the final re-validation being clean (zero blocking
  findings, per the definition above).

**Out of scope:** changing WHAT the validators check (plans 027 adversarial
audit, 028 seam contracts); changing mstack-run's pickup gate (plan 029). This
plan only adds the re-validate-after-edit loop to the doctor.

## Tasks

1. At the start of Step 2, capture `PLAN_HASHES` (path→`shasum`) for every plan
   file. Recompute and diff against it to derive the modified set; recapture at
   the top of each loop round so each round sees only its own edits. Do NOT use
   `git status --porcelain` (status-class comparison misses already-dirty files).
2. After the autonomous auto-fix sections (autonomy / testability /
   verification / trap), recompute hashes and derive the changed set (plans
   whose hash differs from `PLAN_HASHES`).
3. Add "Step 4b: Re-validate modified plans" — over the changed set, re-run the
   Step 3 per-plan structural validation + Step 2 scoring/auto-fixes, plus the
   per-modified-plan slice of any finding-producing check that drove an edit
   (seam diff on incident edges, plan 028; adversarial audit, plan 027). Do NOT
   re-run Step 2b learnings, Step 2c frames, or the full cross-plan agent.
4. Wrap the auto-fix + Step 4b phases in a loop: if a round applied any edit,
   repeat; stop when a round makes no edits or after 3 rounds (a hard cap).
5. After the loop, evaluate the FINAL file state: a plan is `ready`-eligible
   only if it has ZERO blocking findings (structural ERRORS, unresolved
   [critical] frame findings, GENUINE audit findings, blocking SEAM findings).
   On cap-with-residual-blocking-findings, force the verdict to `needs-fixes` and
   list residuals; forbid `ready`. This is an absolute-count gate, not a
   no-new-errors gate.
6. After Step 5 reviews, recompute hashes once more and re-validate any plan a
   review edited before finalizing its verdict. Gate Step 6's per-plan verdict
   and the unattended-execution summary on this final re-validation; log
   "Re-validated N modified plans: M clean, K need fixes".

## Verification

Checks:
- [assert] grep -ni "Step 4b" skills/mstack-plan-doctor/SKILL.md | grep -i "re-validate"
- [cmd] grep -qiE "re-validat(e|ion)" skills/mstack-plan-doctor/SKILL.md
- [cmd] grep -qiE "cap of 3|3 rounds|max(imum)? 3 (re-validation )?rounds" skills/mstack-plan-doctor/SKILL.md
- [cmd] grep -qiE "shasum|content hash" skills/mstack-plan-doctor/SKILL.md
- [cmd] grep -qiE "zero blocking (finding|error)" skills/mstack-plan-doctor/SKILL.md
- [cmd] awk '/^## Step 4: Report/{a=NR} /^## Step 4b/{b=NR} /^## Step 5/{c=NR} END{exit !(a&&b&&c&&a<b&&b<c)}' skills/mstack-plan-doctor/SKILL.md
- [cmd] grep -qiE "never (silently )?ready|not .* ready|forbid .*ready" skills/mstack-plan-doctor/SKILL.md
- [manual] dry-run plan-doctor on a backlog with a deliberately self-contradictory edit; confirm the loop flags it rather than reporting ready
- [manual] dry-run with a pre-existing (not newly-introduced) structural error on a modified plan; confirm the absolute-count gate reports needs-fixes, not ready
