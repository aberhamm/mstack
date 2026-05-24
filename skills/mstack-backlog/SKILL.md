---
name: mstack-backlog
description: |
  View and interactively manage the plan backlog. Shows all plans in
  priority order with dependencies, then lets you reprioritize, defer,
  drop, or stash plans. The grooming/triage tool between status
  (read-only summary) and plan-doctor (validation).
triggers:
  - show the backlog
  - review the backlog
  - what's queued up
  - reprioritize
  - reorder plans
  - backlog grooming
  - triage the backlog
allowed-tools:
  - Bash
  - Read
  - Edit
  - AskUserQuestion
---

You are running `/mstack-backlog`. This is an interactive backlog
grooming tool.

## Setup

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
SCRIPTS_DIR="$SKILL_DIR/scripts"
```

Find the plans directory:

```bash
if [ -d "$REPO_ROOT/docs/plans" ]; then
  PLANS_DIR="$REPO_ROOT/docs/plans"
elif [ -d "$REPO_ROOT/plans" ]; then
  PLANS_DIR="$REPO_ROOT/plans"
else
  echo "No plans directory found."
  exit 1
fi
```

## Step 1 — Display the backlog

Read all plan files and build a table. For each `.md` file in the plans
directory, extract frontmatter fields: `id`, `title`, `status`, `priority`,
`blocked-by`.

Sort by:
1. Status group: `in-progress` first, then `pending`, then `blocked`
2. Within each group: by `priority` (lowest first), then by `id` as tiebreaker
3. Plans without a `priority` field sort by their `id`

Display format:

```
BACKLOG
═══════

In Progress (N):
  #  Pri  ID   Title                                    Blocked by
  1   —   003  Implement auth endpoints                 —

Pending (N):
  #  Pri  ID   Title                                    Blocked by
  2   1   005  Add rate limiting                        —
  3   2   007  Refactor auth middleware                 —
  4   3   008  Add webhook retry logic                  [005]
  5   —   010  Add admin dashboard                      —

Blocked (N):
  #  Pri  ID   Title                                    Blocked by
  6   —   009  Migrate to edge functions                [007, 008]

Done: 4 plans | Failed: 1 plan | Skipped: 0
```

Notes:
- `#` is the display row number (for interactive commands)
- `Pri` shows the `priority:` field value, or `—` if unset
- `Blocked by` shows dependency IDs or `—`
- Done/failed/skipped are just a count summary at the bottom

## Step 2 — Interactive loop

After displaying the table, ask what the user wants to do:

```
Actions: prioritize, defer, drop, stash, done
```

Then wait for user input. Parse their instruction in natural language:

### prioritize / reorder / move

Examples:
- "move 010 to position 2"
- "set 010 priority to 1"
- "make admin dashboard the next thing"
- "swap 005 and 007"

Implementation: edit the `priority:` field in the target plan file(s).
When setting a plan to position N, assign it a priority value that places
it in the right slot relative to neighbors. Use integers — if plan at
position 2 has priority 2 and position 3 has priority 3, inserting at
position 2 means giving it priority 2 and bumping others up.

After reordering, redisplay the table to confirm the new order.

### defer

Examples:
- "defer 010"
- "defer admin dashboard"

Implementation:
1. Set `status: blocked` in the plan's frontmatter
2. Add `deferred: <YYYY-MM-DD>` and `deferred-reason: "user decision"`

### drop

Examples:
- "drop 010"
- "skip admin dashboard"

Implementation:
1. Set `status: skipped` in the plan's frontmatter
2. Add `skipped: <YYYY-MM-DD>`

### stash

Examples:
- "stash 010"
- "stash admin dashboard — not ready to plan this yet"

Implementation:
1. Read the plan file
2. Create a stash file in `.mstack/stashed/` with the plan's title,
   its Requirements section as "Context", and any open questions from
   the plan as "Open Questions"
3. Set the plan's `status: skipped` with `skipped-reason: "stashed"`
4. Print: `Stashed: "<title>" → .mstack/stashed/<filename>`

### done

Exit the interactive loop. Print: "Backlog grooming complete."

## After each action

After any modification:
1. Redisplay the updated table
2. Ask if there's anything else

Do not commit changes automatically. The user can commit when they're
satisfied with the final state.

## Rules

- Never modify plan content (Requirements, Design, Tasks sections) —
  only frontmatter fields.
- Never delete plan files — use status changes instead.
- Never auto-commit. Let the user review the final state.
- Show the updated table after every change so the user sees the result.
