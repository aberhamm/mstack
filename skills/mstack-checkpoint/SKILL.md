---
name: mstack-checkpoint
description: |
  Crash recovery state: facts, not reasoning. Writes machine-readable
  checkpoint after each plan so a fresh session can resume without losing
  progress. Three sections: attempts (what was tried + errors), user_context
  (things the user pointed out), counters (progress metrics).

  Called by mstack-run automatically after each plan. Internal skill,
  not intended for direct user invocation. Use /mstack-status to view
  checkpoint data.
allowed-tools:
  - Bash
  - Read
---

You manage crash recovery state for the autonomous worker. A checkpoint
captures facts (observable errors, user-provided context, and progress
counters) so a fresh session can resume with clean reasoning.

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

## Scripts

All read/write/prune logic lives in `checkpoint.sh`. Resolve the scripts
directory:

```bash
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SCRIPTS_DIR" ] && break
  [ -d "${_skill_base}/mstack-run/scripts" ] && SCRIPTS_DIR="${_skill_base}/mstack-run/scripts"
done
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/checkpoint.sh" read` | Print latest.json contents (exit 2 if none) |
| `bash "$SCRIPTS_DIR/checkpoint.sh" dashboard` | Print formatted dashboard from latest checkpoint |
| `bash "$SCRIPTS_DIR/checkpoint.sh" write '<json>'` | Write JSON to latest.json + timestamped copy |
| `echo '<json>' \| bash "$SCRIPTS_DIR/checkpoint.sh" write` | Same, via stdin |
| `bash "$SCRIPTS_DIR/checkpoint.sh" prune` | Delete timestamped copies older than 7 days + reviews older than 30 days |

## Schema

When constructing checkpoint JSON (for the `write` command), use this schema:

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
    }
  ],

  "user_context": [
    "auth middleware was recently refactored, check imports",
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

## Standalone mode (`/mstack-checkpoint`)

When the user invokes this skill directly:

1. Run `bash "$SCRIPTS_DIR/checkpoint.sh" dashboard`
2. If it prints `NO_CHECKPOINT`, tell the user: "No checkpoint data yet. Checkpoints are created automatically by /mstack-run after each plan."
3. Otherwise, display the formatted output directly. The script produces the full dashboard.

## Automatic mode (called by mstack-run)

After each plan completes (success or failure), the worker constructs the
checkpoint JSON and writes it:

1. Read existing checkpoint: `bash "$SCRIPTS_DIR/checkpoint.sh" read`
2. Construct updated JSON following the schema above:
   - Append the current plan's outcome to `attempts` (observable errors only)
   - Update `counters` with current progress
   - Preserve `user_context` from previous checkpoint (accumulates across plans)
3. Write: `bash "$SCRIPTS_DIR/checkpoint.sh" write '<json>'`

## Recovery flow (how mstack-run uses checkpoints)

When mstack-run starts a new iteration (Step 1):

1. Run `bash "$SCRIPTS_DIR/checkpoint.sh" read`
2. If a checkpoint exists:
   - Check `plan_status` of the last recorded plan
   - If `"in-progress"`: the previous session crashed mid-plan. Resolve
     `${plan_id}: <title>` via `plan_label` (`source "$SCRIPTS_DIR/lib.sh";
     plan_label "$plan_id"`) — do not cite a bare id. Log: "Previous session
     crashed during plan ${plan_id}: <title>. Plan remains in-progress.
     Pick-next will skip to the next plan."
   - If `"done"` or `"failed"`: normal flow, pick the next plan
3. Carry forward `user_context` into the new session's working memory
4. Log the recovery: "Recovered from checkpoint: N plans done, M remaining"

## Adding user context

If the user provides context during a session ("remember that X", "note that Y"),
the worker appends it to the `user_context` array in the next checkpoint write.
User context persists across plans until the user explicitly asks to clear it.
