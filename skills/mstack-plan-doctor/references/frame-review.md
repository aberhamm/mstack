# Step 2c: Multi-frame Review

After learnings check, review each pending/blocked plan through 3
deterministically-selected cognitive frames to surface blind spots that
single-perspective scoring misses.

### Setup

Resolve and read the cognitive frames library:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
FRAMES_FILE="$MSTACK_ROOT/skills/mstack-shared/cognitive-frames.md"
if [ -f "$FRAMES_FILE" ]; then
  cat "$FRAMES_FILE"
else
  echo "No cognitive frames file available"
fi
```

This file defines all review frames, their behavioral biases, review checklists,
keyword lists, and the deterministic selection algorithm. If the file is not found,
skip Step 2c and proceed to Step 3 (frame review is additive, not blocking).

### For each pending/blocked plan

**1. Select 3 frames using the deterministic selection rules:**

Follow the algorithm from `cognitive-frames.md` Selection Rules exactly:

- **Step 1 (mandatory):** Always include Simplicity Advocate Review.
- **Step 2 (domain match):** Scan the plan's file paths and text for domain
  signals. Apply the first matching rule from the ordered signal table. At most
  one domain match.
- **Step 3 (fill remaining):** From unselected review frames, count keyword
  matches against the plan's title, description, file paths, and task list.
  Rank by match count descending; break ties by frame index (earlier wins).
  Select the top frame(s) needed to reach exactly 3 total.

**2. Evaluate the plan through each selected frame:**

For each frame, apply its **review checklist** and **behavioral bias** (not its
name as a persona -- use behavior-first instructions, not identity claims). Read
the plan's Requirements, Design, Tasks, and Verification sections. Produce 0-3
findings per frame. Each finding is either:

- **[critical]**: A concrete gap that would cause a failure, security hole,
  production incident, or user-facing defect. Missing auth, unbounded queries,
  silent failures, data loss risks.
- **[advisory]**: A valid concern that improves quality but is not blocking.
  Missing loading states, optimization opportunities, documentation gaps.

**3. Produce structured findings:**

```
FRAME REVIEW: Plan {id} "{title}"
  Frames: {Frame1}, {Frame2}, {Frame3}

  {Frame1}:
    [critical] {description}
    [advisory] {description}
  {Frame2}:
    [advisory] {description}
  {Frame3}:
    (no findings)

  Impact: -{N} autonomy-readiness ({N} critical finding(s) unaddressed)
```

### Scoring integration

Each unaddressed **[critical]** finding deducts 1 point from the plan's
**autonomy-readiness** score. Advisory findings do not affect the score.
Apply deductions after the Step 2 base scoring and Step 2b learnings
deductions. The total autonomy-readiness score is:

```
final_autonomy = base_autonomy - learnings_deductions - frame_critical_count
```

### Auto-fix: frame findings

When a critical frame finding identifies a missing concern (e.g., no auth
middleware, no error handling, no input validation), attempt to auto-fix it
using the same pattern as the existing autonomy-readiness auto-fix in Step 2:

1. Read the codebase to infer the appropriate mitigation (check existing
   patterns, sibling implementations, project conventions).
2. Add a line to the plan's Design section:
   `**{concern}:** {one-line mitigation}`
3. Re-check: if the finding is now addressed by the added detail, remove the
   autonomy-readiness deduction for that finding.
4. Log what was fixed:

```
Auto-fixed frame findings:
  042, "Add user avatars": added "Auth middleware: apply requireAuth to upload endpoint" to Design
    (Security Review [critical] resolved, autonomy restored +1)
  045, "Redesign settings": added "Error states: show user-friendly error with retry button" to Design
    (End User [critical] resolved, autonomy restored +1)
```

If a critical finding cannot be resolved by adding detail (e.g., it requires
an architectural decision with genuine tradeoffs), leave the deduction in place
and flag it as a **user challenge** for the architect.

### Scorecard update

The scorecard output from Step 2 is extended to include frame information:

**Before (Step 2 only):**
```
Plan 042, "Add user avatars"
  Clarity: 8  Testability: 9  Scope-fit: 7  Autonomy: 6  Trap: 7
```

**After (with Step 2c frame review):**
```
Plan 042, "Add user avatars"
  Clarity: 8  Testability: 9  Scope-fit: 7  Autonomy: 6 (-1 frame: auth gap)  Trap: 7
  Frames: Security Review, End User, Simplicity Advocate
```

The `(-N frame: {summary})` notation shows how many autonomy points were
deducted by frame findings and a brief description of the most significant
finding. If no critical findings, omit the parenthetical.
