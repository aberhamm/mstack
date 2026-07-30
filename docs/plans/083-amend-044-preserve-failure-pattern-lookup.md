---
id: 083
title: amend plan 044 to preserve investigate's failure-pattern lookup
status: pending
blocked-by: []
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Pending plan 044 (`docs/plans/044-retire-or-relocate-learnings-subsystem.md`,
already carrying `reviews: - type=eng verdict=approved date=2026-07-22`)
retires the learnings subsystem in favor of committed docs. The audit found
its replacement covers the wrap-up router and Step-4 pitfall surfacing, but
NOT `mstack-investigate`'s file-keyed pitfall lookup
(`skills/mstack-investigate/SKILL.md:88-90` "Check learnings ... prior
investigations in the same area", and `:106` "does the failing file have prior
learnings flagged as pitfalls?") — a per-file failure-pattern match consulted
before forming a hypothesis, which AGENTS.md prose cannot replicate (not keyed
by file path, no per-file accumulation). 044's Design lists investigate's
references for removal with no substitute (044:82-85, Task 4 at 044:119-122),
and its acceptance criteria (044:146-158) never mention the capability.

This plan, when executed, EDITS 044. It does not perform 044.

**Acceptance criteria**

- [ ] 044 gains a migration task that either (a) routes investigation pitfall
      findings to a committed, file-path-keyed sink, or (b) records an
      explicit decision that the capability is dropped and why. The amendment
      picks exactly one; **preserve (a) is the default recommendation**.
- [ ] 044's Design records the decay-math context: `learnings.sh:169-179`
      applies -1 confidence per PRUNE INVOCATION once an entry is 14+ days
      unverified, and prune runs before every plan (`mstack-run` Step 3c,
      SKILL.md:627-632) — so a busy session destroys the store in a day. The
      store's thinness indicts the decay bug, not the idea of per-file
      failure patterns.
- [ ] After amending, 044's `needs-review:` is set to `eng` — content changed
      after approval, so the gate is re-raised. (Raising a gate is allowed
      for any actor per AGENTS.md; clearing one is not. The existing
      `reviews:` entry is NOT touched — no record is removed or weakened, so
      `assert-no-downgrade` stays green.)
- [ ] 044's `review-required: eng` and `reviews:` block are byte-identical
      before and after the amendment.

## Design

Proposed sink for option (a): `docs/pitfalls.md`, entry format one block per
finding keyed by path so investigate can grep it:

```markdown
## path: skills/mstack-run/scripts/pick-next.sh
- 2026-07-30 (plan 055): eval on user tokens — validate before expanding.
```

Investigate's Phase 1/2 checks become
`grep -A3 "^## path: <failing-file>" docs/pitfalls.md`, and the
capture side routes through the wrap-up harvest / investigate Phase 4 as a
propose-by-default doc edit — consistent with 044's committed-docs direction,
just file-keyed. The amendment writes this into 044's Design and Tasks (task
ordering: before 044's Task 4 removes the read sites) and updates 044's
acceptance criteria to name the capability's disposition.

Backlog wiring note: 044 already carries `blocked-by: [083]` (verified in the
working tree at validation time), so 044 cannot run before this amendment
lands. Do not re-add it; just confirm it is still present.

Testing approach: unit-only.

**Files expected to change:**

- `docs/plans/044-retire-or-relocate-learnings-subsystem.md`: Design addition
  (sink format + decay-math context), new migration task, acceptance-criteria
  line, `needs-review: none` → `eng`. Frontmatter otherwise untouched.

**Out of scope:** fixing `learnings.sh` bugs (044 deletes the file);
performing 044 itself (no skill/script edits, no `docs/pitfalls.md` creation
— that happens when 044 runs); touching 044's `reviews:` or
`review-required:`; editing `mstack-investigate` now.

## Tasks

1. Re-read 044 in full and confirm the investigate lookup still has no
   substitute in its current text (it may have drifted since authoring).
2. Add the decay-math context paragraph to 044's Design (Requirements
   rationale area, near the RETIRE decision).
3. Add the migration task (file-path-keyed `docs/pitfalls.md` sink, format as
   above, ordered before 044's read-site removal task) and the matching
   acceptance criterion. If during editing the drop option is deliberately
   chosen instead, record the decision and rationale in 044's Design.
4. Update 044's Design "Files expected to change" investigate line to point
   at the new sink instead of bare removal.
5. Set 044 `needs-review: eng`; verify `reviews:`/`review-required:` are
   unchanged; run `review-gate.sh assert-no-downgrade` on 044.

## Verification

Checks:

- [assert] `grep -c 'pitfall' docs/plans/044-retire-or-relocate-learnings-subsystem.md` → >= 4 (pre-amendment count is exactly 2 — lines 46 and 80 — so >= 4 proves the amendment added pitfall-sink content; a >= 2 check would pass vacuously)
- [cmd] `grep -q 'needs-review: eng' docs/plans/044-retire-or-relocate-learnings-subsystem.md`
- [cmd] `grep -q 'type=eng verdict=approved date=2026-07-22' docs/plans/044-retire-or-relocate-learnings-subsystem.md`
- [cmd] `grep -q 'review-required: eng' docs/plans/044-retire-or-relocate-learnings-subsystem.md`
- [cmd] `bash skills/mstack-run/scripts/review-gate.sh assert-no-downgrade docs/plans/044-retire-or-relocate-learnings-subsystem.md`
- [assert] `grep -c 'decay' docs/plans/044-retire-or-relocate-learnings-subsystem.md` → >= 3 (pre-amendment count is exactly 2 — lines 41 and 50 — so >= 3 proves the decay-math paragraph landed; a >= 1 check would pass vacuously)
