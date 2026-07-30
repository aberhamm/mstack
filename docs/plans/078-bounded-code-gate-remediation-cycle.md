---
id: 078
title: run one bounded automated remediation cycle on an open code gate
status: pending
blocked-by: [074, 077]
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

`needs-review: code` is an explicitly human-only dead end today: both
`AGENTS.md` ("an unresolved code-review finding has no automated remediation
path the way eng/design/ceo do... it needs a human to re-run
mstack-code-review or fix and re-record") and mstack-run Step 7a
(`skills/mstack-run/SKILL.md:874-879`) say so — yet the named remediation,
`mstack-code-review`, is itself an automated skill. When Step 7a's
`assert-completable` blocks on a `code` gate, the loop should attempt exactly
one automated remediation cycle before parking the plan on a human.

**Acceptance criteria**

- [ ] When Step 7a blocks a plan on an open `code` gate, mstack-run runs one
      remediation cycle: (1) mstack-investigate against the recorded
      findings, (2) re-run mstack-code-review so the `code` verdict is
      re-recorded via the sanctioned path (its Step 5b,
      `skills/mstack-code-review/SKILL.md:227-232` — `review-gate.sh record`),
      (3) re-run `assert-completable`.
- [ ] If step (3) still fails: terminal block (`status: blocked`,
      `needs-review: code`), and notify the human via plan 073's channel.
      The human is the named owner from that point; no second cycle, ever.
- [ ] A deterministic checkpoint marker prevents re-entry: a plan whose
      checkpoint already records a code-remediation attempt goes straight to
      the terminal block on a subsequent open `code` gate.
- [ ] Plan 035 is preserved verbatim: only mstack-code-review records the
      `code` verdict; the orchestrator and investigate never call
      `review-gate.sh record`, never edit `reviews:`/`review-required`.
- [ ] Investigate runs under its existing strike bounds (3 per category, 9
      total, `skills/mstack-investigate/SKILL.md:139-143`) — no new budget.
- [ ] `.mstack/reviews/plan-<id>.json` carries enough finding detail to
      investigate against (see Design — today it records only counts).

## Design

Trigger point: inside Step 7a's blocked-outcome path (SKILL.md:855-896),
branch when the still-open type set includes `code`. The cycle invokes
mstack-investigate and mstack-code-review through the identical prose
skill-invocation contract Step 5 (failure path) and Step 6 already use — no
new invocation mechanism. Input for investigate is
the derived cache `.mstack/reviews/plan-<id>.json` — acceptable as an INPUT
because the gate itself still trusts only frontmatter (`AGENTS.md` reviews
doctrine); the cache being non-authoritative is fine for pointing a debugger
at findings. Verified gap: the JSON today records only counts and reviewer
metadata (`findings_total` etc., mstack-code-review SKILL.md:210-225), not
the findings themselves — so this plan also extends mstack-code-review's
Step 5 artifact write with a `findings` array: severity, file, one-line
description, and `status` (`fixed|noted`) per retained finding. The `status`
field is not optional decoration: `code_verdict_from_findings`'s documented
jq fallback already counts `findings[]` entries whose status is not "fixed"
when the counters are absent (lib.sh:551-554), so the array must carry it
for the counters and the array to never diverge in meaning. The verdict
mapping itself stays `code_verdict_from_findings` (lib.sh:545-559),
untouched.

Commit seam with plan 039: `assert-completable` runs at step 1 of the 7a
order, BEFORE the stage-and-commit (step 5), so the cycle operates on the
still-uncommitted work tree. Any file the remediation touches is appended to
the result block's MODIFIED/CREATED/DELETED lists before the 7a
stage-and-commit resumes, so `assert-work-committed` (plan 039, step 6b)
sees remediation edits committed — the cycle must never leave
plan-attributable dirt for the 039 gate to trip on.

Re-entry marker: checkpoint, not plan frontmatter (keeps frontmatter clean;
checkpoint counters are the established per-plan progress store, e.g.
`health_attempts_this_plan`, `skills/mstack-checkpoint/SKILL.md:98-102`).
Add counter `code_remediation_attempted_plan: <id>` written via
`checkpoint.sh` before the cycle starts (write-ahead: a crash mid-cycle must
not buy a second cycle). On a later open `code` gate for the same plan id,
the marker short-circuits to the terminal block. On second failure the block
message names the human explicitly: "one automated remediation cycle
exhausted — a human must fix and re-run /mstack-code-review", and the plan
073 notification fires with that text.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: Step 7a `code`-gate branch — cycle, marker
  check, terminal block + notify.
- `skills/mstack-code-review/SKILL.md`: `findings` array in the JSON
  artifact; note that the array feeds remediation.
- `skills/mstack-checkpoint/SKILL.md`: document the new counter.
- `AGENTS.md`: replace "no automated remediation path" with the
  one-bounded-cycle rule and its terminal state.

**Out of scope:** any second cycle or configurable cycle count; letting
investigate or mstack-run record/clear any review verdict (plan 035);
changing `assert-completable` or `code_verdict_from_findings`; remediating
eng/design/ceo gates (plan-doctor Step 5 owns those, SKILL.md:878-879).

## Tasks

1. Extend mstack-code-review's JSON artifact with the `findings` array
   (severity, file, description, `status` per lib.sh's fallback contract).
2. Add the checkpoint counter write/read (document in mstack-checkpoint).
3. Write the Step 7a `code`-gate branch: marker check → investigate against
   the cache → re-run mstack-code-review → re-assert → terminal block +
   plan-073 notify on failure.
4. Update the two "no automated remediation path" passages (`AGENTS.md`
   and mstack-run `SKILL.md:874-879`) to the new rule.
5. Run the smoke set.

## Verification

Checks:

- [cmd] `grep -q "code_remediation_attempted" skills/mstack-run/SKILL.md`
- [cmd] `grep -q "code_remediation_attempted" skills/mstack-checkpoint/SKILL.md`
- [assert] `grep -c "findings" skills/mstack-code-review/SKILL.md`
- [cmd] `! grep -q "no automated remediation path" skills/mstack-run/SKILL.md`
- [cmd] `grep -q "one.*remediation cycle" AGENTS.md || grep -qi "bounded.*remediation" AGENTS.md`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
