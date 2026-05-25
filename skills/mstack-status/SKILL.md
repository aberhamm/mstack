---
name: mstack-status
description: |
  Read-only dashboard showing backlog state, health trends, open reviews,
  active investigations, and session stats. Answers "where are we?" without
  modifying anything. Reads from plan files, health history, review artifacts,
  and the latest checkpoint.
triggers:
  - where are we
  - backlog status
  - what's next
  - show status
  - how's the backlog
allowed-tools:
  - Bash
  - Read
---

You produce a read-only status dashboard for the mstack backlog. You never
modify files — only read and report.

User input (optional):

```
$ARGUMENTS
```

## Auto-init

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Scripts

All dashboard logic lives in `status.sh`. Resolve the scripts directory:

```bash
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
[ -d "$SCRIPTS_DIR" ] || SCRIPTS_DIR="${HOME}/.claude/skills/mstack-run/scripts"
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/status.sh" dashboard` | Full status dashboard |
| `bash "$SCRIPTS_DIR/status.sh" plan <id>` | Detailed status for one plan |

## Update check

Before showing the dashboard, check if mstack itself has updates:

```bash
MSTACK_BIN="${HOME}/.config/skillshare/skills/mstack/bin"
[ -d "$MSTACK_BIN" ] || MSTACK_BIN="${HOME}/.claude/skills/mstack/bin"
UPDATE_MSG=$("$MSTACK_BIN/mstack-update-check" 2>/dev/null || true)
```

If `$UPDATE_MSG` is non-empty, print it at the top of the dashboard
output (before the status table) as a single notice line.

## Default mode (no argument or dashboard)

Run `bash "$SCRIPTS_DIR/status.sh" dashboard` and present the output
directly to the user. The script produces:

```
MSTACK STATUS
=============
Project: <project name>
Branch:  <current branch>
Date:    <today>

BACKLOG
  Done:        5 plans
  Failed:      1 plan
  Pending:     3 plans
  Next ready:  044 — "Add rate limiting to API endpoints"

  Recent completions:
    043  done   2026-05-19  "Refactor user service"
    042  done   2026-05-18  "Fix scraper bug"

HEALTH TREND
  Latest: 9.1/10
  Trend:  9.4 → 8.8 → 9.1

STASHED
  3 threads (oldest: 12 days)
    "Auth token refresh strategy" (May 24)
    "Notification architecture" (May 21)
    "Edge function migration" (May 19)

REVIEWS
  Last review: plan-042 — 3 findings, 2 fixed

SESSION
  Plans this session: 3 completed, 1 failed
  User notes:         2 carried forward
```

If the script exits with code 2 (no plans directory), tell the user:
"No plans directory found. Run /mstack-plan-backlog to create one."

## Plan detail view

If the user passes a plan ID as argument (e.g., `/mstack-status 042`):

Run `bash "$SCRIPTS_DIR/status.sh" plan 042` and present the output:

```
PLAN 042: Fix scraper empty payload bug
========================================
Status:     done
Completed:  2026-05-18
Blocked by: none

File: docs/plans/042-fix-scraper-bug.md
```
