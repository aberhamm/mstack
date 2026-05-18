---
name: mstack-checkpoint
description: |
  Crash recovery state — facts, not reasoning. Writes machine-readable
  checkpoint after each plan so a fresh session can resume without losing
  progress. Three sections: attempts (what was tried + errors), user_context
  (things the user pointed out), counters (progress metrics).

  Called by mstack-run automatically after each plan. Also callable
  standalone to view the current checkpoint dashboard.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

You manage crash recovery state for the autonomous worker. A checkpoint
captures facts — observable errors, user-provided context, and progress
counters — so a fresh session can resume with clean reasoning.

User input (optional):

```
$ARGUMENTS
```

## Key principle: facts, not reasoning

A checkpoint does NOT carry forward agent reasoning, interpretations, or
hypotheses. A fresh session gets evidence and forms its own conclusions.
This prevents poisoned context windows where a wrong hypothesis from a
crashed session biases the next one.

**Good checkpoint data:**
- "tsc reported 3 errors in src/api/handler.ts: TS2345 on lines 42, 55, 78"
- "user said: the auth middleware was recently refactored, check imports"
- "health attempts: 2/2 used, investigate strikes: 1/3 used"

**Bad checkpoint data (never write this):**
- "I think the issue is a race condition in the auth flow"
- "The fix probably needs to restructure the middleware chain"
- "Based on my analysis, the root cause is..."

## Storage

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$REPO_ROOT/.mstack/checkpoints"
grep -q "^\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".mstack/" >> "$REPO_ROOT/.gitignore"
```

- **Latest:** `$REPO_ROOT/.mstack/checkpoints/latest.json`
- **Timestamped copy:** `$REPO_ROOT/.mstack/checkpoints/<ISO-timestamp>.json`

## Schema

```json
{
  "ts": "2026-05-19T14:30:00Z",
  "branch": "main",
  "plan_id": "042",
  "plan_status": "done",

  "attempts": [
    {
      "plan_id": "041",
      "action": "implement",
      "outcome": "success",
      "errors": []
    },
    {
      "plan_id": "042",
      "action": "health-check",
      "outcome": "fail",
      "errors": ["tsc: TS2345 at src/api/handler.ts:42"]
    },
    {
      "plan_id": "042",
      "action": "investigate-strike-1",
      "outcome": "fail",
      "errors": ["hypothesis: missing import — wrong, import exists"]
    },
    {
      "plan_id": "042",
      "action": "investigate-strike-2",
      "outcome": "success",
      "errors": []
    }
  ],

  "user_context": [
    "auth middleware was recently refactored — check imports",
    "skip plan 045 for now, depends on external API not ready"
  ],

  "counters": {
    "plans_completed": 3,
    "plans_failed": 1,
    "plans_remaining": 4,
    "health_attempts_this_plan": 2,
    "investigate_strikes_this_plan": 2,
    "health_trend": [9.4, 8.8, 9.1],
    "session_started": "2026-05-19T13:00:00Z"
  }
}
```

## Modes

### Automatic mode (called by mstack-run)

After each plan completes (success or failure), the worker writes checkpoint
state. This is not a separate skill invocation — the worker runs the logic
inline:

1. Read `latest.json` if it exists (previous state)
2. Append the current plan's outcome to `attempts`
3. Update `counters` with current progress
4. Preserve `user_context` from previous checkpoint (accumulates across plans)
5. Write `latest.json` and a timestamped copy

**What to capture per plan:**
- Plan ID and final status (done/failed)
- Action taken (implement, health-check, investigate-strike-N)
- Observable errors (compiler output, test failures) — not interpretations
- Counter updates

### Manual mode (`/mstack-checkpoint`)

When the user invokes this skill directly, present a dashboard from the
latest checkpoint:

```
CHECKPOINT DASHBOARD
====================
Last updated: 2026-05-19 14:30 UTC
Branch: main

PROGRESS
  Completed: 3 plans (041, 042, 043)
  Failed:    1 plan (040 — gate red after 3 strikes)
  Remaining: 4 plans
  Next:      044 — "Add rate limiting to API endpoints"

CURRENT STATE
  Plan 042: done
  Health: 2 attempts used (gate passed on attempt 2)
  Investigate: 2 strikes used (fixed on strike 2)
  Health trend: 9.4 → 8.8 → 9.1

USER CONTEXT (carried forward)
  - auth middleware was recently refactored — check imports
  - skip plan 045 for now, depends on external API not ready

RECENT ATTEMPTS
  042 implement     → success
  042 health-check  → fail (tsc: TS2345 at src/api/handler.ts:42)
  042 investigate-1  → fail (wrong hypothesis)
  042 investigate-2  → success (fixed: missing type assertion)
  042 health-check  → pass
```

### Adding user context

If the user provides context during a session ("remember that X", "note that Y"),
the worker appends it to the `user_context` array in the next checkpoint write.
User context persists across plans until the user explicitly asks to clear it.

## Recovery flow (how mstack-run uses checkpoints)

When mstack-run starts a new iteration (Step 1):

1. Read `$REPO_ROOT/.mstack/checkpoints/latest.json`
2. If a checkpoint exists:
   - Check `plan_status` of the last recorded plan
   - If `"in-progress"`: the previous session crashed mid-plan. The plan file's
     frontmatter `status: in-progress` tells pick-next.sh to skip it (it was
     already claimed). Log: "Previous session crashed during plan ${plan_id}.
     Plan remains in-progress — pick-next will skip to the next plan."
   - If `"done"` or `"failed"`: normal flow, pick the next plan
3. Carry forward `user_context` into the new session's working memory
4. Log the recovery: "Recovered from checkpoint: N plans done, M remaining"

## Cleanup

Timestamped checkpoint files older than 7 days can be pruned:

```bash
find "$REPO_ROOT/.mstack/checkpoints" -name "*.json" ! -name "latest.json" -mtime +7 -delete
```

The worker runs this during Step 1 (startup) to prevent unbounded growth.
