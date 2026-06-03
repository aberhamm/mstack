---
id: 2
title: Wire frame-based review into plan-doctor
status: in-progress
blocked-by: [1]
allows-migrations: false
needs-review: none
created: 2026-05-26
---

## Requirements

Plan-doctor scores plans on 4 dimensions but reviews from a single perspective. With the
cognitive frames library from plan 001 in place, plan-doctor needs a new sub-step that
reviews each plan through 3 deterministically-selected frames and surfaces blind spots.

Frame findings must have clear action semantics: they are not just commentary. Each
unaddressed finding lowers the plan's autonomy-readiness score by 1 point, matching
the existing learnings-based deduction pattern. This means frame findings have teeth:
they affect whether the plan passes the autonomy threshold.

**Acceptance criteria:**

- [ ] Plan-doctor Step 2 includes a new "Step 2c: Multi-frame review" sub-step
- [ ] For each pending/blocked plan, 3 frames are selected using the deterministic rules from `skills/mstack-shared/cognitive-frames.md`
- [ ] Each frame reviews the plan independently and produces 0-3 findings
- [ ] Findings are tagged with frame name and severity (critical/advisory)
- [ ] Critical findings deduct 1 point from autonomy-readiness per finding
- [ ] Advisory findings are non-blocking warnings in the report
- [ ] Frame findings appear in the plan scorecard output alongside existing dimensions
- [ ] Auto-fix attempt: if a critical frame finding can be resolved by adding detail to the Design section (same pattern as existing autonomy auto-fix), do it automatically
- [ ] The plan-doctor reads `skills/mstack-shared/cognitive-frames.md` to get frame definitions and selection rules

## Design

This adds a sub-step after the existing Step 2b (learnings check). The current order is
Step 2 (scoring) → Step 2b (learnings check). The new order will be Step 2 → Step 2b →
Step 2c (multi-frame review). This preserves existing step numbering; 2c comes after 2b
chronologically. The implementation is entirely within plan-doctor's SKILL.md.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: add Step 2c with frame review instructions, update scorecard output format, update auto-fix logic

**Approach:**

Insert a new `## Step 2c: Multi-frame review` section after Step 2b (learnings check). The section:

1. Instructs the agent to read `skills/mstack-shared/cognitive-frames.md`
2. For each plan being validated, apply the selection rules to pick 3 frames
3. For each selected frame, evaluate the plan using its review checklist and behavioral bias (behavior-first, not persona-first, per frame library design)
4. Produce findings in structured format:

```
FRAME REVIEW: Plan 042 "Add user avatars"
  🔍 Security Review:
    [critical] No auth middleware specified for the upload endpoint
    [advisory] Consider rate limiting on file uploads
  🔍 End User:
    [advisory] No loading state mentioned for avatar upload UX
  🔍 Simplicity Advocate:
    (no findings)

  Impact: -1 autonomy-readiness (1 critical finding unaddressed)
```

5. Critical findings trigger auto-fix: add the missing detail to the plan's Design section (same pattern as existing autonomy-readiness auto-fix in Step 2)
6. After auto-fix, re-check: if the finding is now addressed, remove the deduction

**Integration with existing scoring:**

The scorecard output changes from:
```
Plan 042: "Add user avatars"
  Clarity: 8  Testability: 9  Scope-fit: 7  Autonomy: 6
```

To:
```
Plan 042: "Add user avatars"
  Clarity: 8  Testability: 9  Scope-fit: 7  Autonomy: 6 (−1 frame: auth gap)
  Frames: Security Auditor, End User, Simplicity Advocate
```

**Out of scope:**

- Trap detection/scoring (plan 003)
- Frame definitions themselves (plan 001)
- Changes to plan-multi or other skills

## Tasks

1. Insert new `## Step 2c: Multi-frame review` section after Step 2b in plan-doctor SKILL.md, including the instruction to read `skills/mstack-shared/cognitive-frames.md` at the top of the new section
2. Define the frame review prompt format: for each plan, apply 3 frames, produce structured findings
3. Define action semantics: critical findings deduct from autonomy-readiness, advisory findings are warnings
4. Add auto-fix integration: when a critical frame finding identifies a missing concern (e.g., auth), add a line to the plan's Design section: `**{concern}:** {one-line mitigation}` (same pattern as the "Auto-fix: autonomy-readiness" section: read codebase, infer the missing concern, edit the plan's Design section, re-score)
5. Update the scorecard output format to include frame names and frame-induced deductions (the `(-1 frame: auth gap)` notation)
6. Update the Step 4 report and Step 6 summary to include frame review stats

## Verification

- [assert] grep 'Step 2c' skills/mstack-plan-doctor/SKILL.md
- [assert] grep 'cognitive-frames.md' skills/mstack-plan-doctor/SKILL.md
- [assert] grep 'critical.*autonomy' skills/mstack-plan-doctor/SKILL.md (critical findings affect autonomy)
- [assert] grep 'Frame' skills/mstack-plan-doctor/SKILL.md | grep -i 'review'
- [assert] grep 'auto-fix' skills/mstack-plan-doctor/SKILL.md | grep -i 'frame'

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | -- | -- |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 0 findings (reviewed full backlog) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 0 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | -- | -- |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | -- | -- |

- **VERDICT:** ENG CLEARED. Ready to implement.
