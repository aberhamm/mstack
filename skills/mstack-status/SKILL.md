---
name: mstack-status
description: |
  Read-only dashboard showing backlog state, health trends, open reviews,
  active investigations, and session stats. Answers "where are we?" without
  modifying anything. Reads from plan files, health history, review artifacts,
  and the latest checkpoint.
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
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

## Step 1 — Find the plans directory

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ -d "$REPO_ROOT/docs/plans" ]; then
  PLANS_DIR="$REPO_ROOT/docs/plans"
elif [ -d "$REPO_ROOT/plans" ]; then
  PLANS_DIR="$REPO_ROOT/plans"
else
  echo "NO_PLANS_DIR"
fi
```

If no plans directory: "No plans directory found. Run /mstack-plan-backlog to create one."

## Step 2 — Read backlog state

Read all `.md` files in the plans directory. Parse frontmatter for `status`,
`id`, `title`, `blocked-by`, `priority`, `completed`, `failed-at`,
`failed-reason`.

Categorize each plan:

- **Done**: `status: done`
- **Failed**: `status: failed`
- **In Progress**: `status: in-progress`
- **Blocked**: `status: blocked`
- **Pending**: `status: pending`
- **Skipped**: `status: skipped`

Sort pending plans by file order (the backlog order from plan-backlog or
manual ordering). Identify the next ready plan: first `pending` plan whose
`blocked-by` dependencies are all `done`.

## Step 3 — Read health trend

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
tail -10 "$REPO_ROOT/.mstack/health-history.jsonl" 2>/dev/null || echo "NO_HEALTH_HISTORY"
```

Parse the last 10 entries for the trend display.

## Step 4 — Read review artifacts

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
ls -t "$REPO_ROOT/.mstack/reviews/"*.json 2>/dev/null | head -5 || echo "NO_REVIEWS"
```

Read the most recent review files for summary stats.

## Step 5 — Read latest checkpoint

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cat "$REPO_ROOT/.mstack/checkpoints/latest.json" 2>/dev/null || echo "NO_CHECKPOINT"
```

## Step 6 — Present the dashboard

```
MSTACK STATUS
=============
Project: <project name>
Branch:  <current branch>
Date:    <today>

BACKLOG
  Done:        5 plans
  Failed:      1 plan (040 — "gate red: TypeScript errors")
  In Progress: 0
  Blocked:     1 plan (045 — blocked by 044)
  Pending:     3 plans
  Next ready:  044 — "Add rate limiting to API endpoints"

  Recent completions:
    043  done   2026-05-19  "Refactor user service to use repository pattern"
    042  done   2026-05-18  "Fix scraper empty payload bug"
    041  done   2026-05-17  "Add pagination to listings API"

HEALTH TREND
  Latest: 9.1/10 (PASS)
  Trend:  9.4 → 8.8 → 8.2 → 9.1 (improving)

REVIEWS
  Last review: plan-042 — 3 findings above threshold, 2 fixed
  Providers:   Claude + Codex

SESSION
  Plans this session: 3 completed, 1 failed
  Health attempts:    2 used on current plan
  Investigate strikes: 0 used
  User notes:         2 carried forward
```

If any section has no data (no health history, no reviews, etc.), show
"No data yet" for that section instead of omitting it.

## Optional: plan detail view

If the user passes a plan ID as argument (e.g., `/mstack-status 042`),
show detailed status for that specific plan:

```
PLAN 042: Fix scraper empty payload bug
========================================
Status:    done
Completed: 2026-05-18
Priority:  high
Blocked by: none

Health checks: 2 attempts (passed on attempt 2)
Review:        3 findings, 2 fixed, 1 noted
Investigation: 2 strikes used (fixed on strike 2)

Files changed:
  src/api/scraper.ts
  src/lib/scrape-result.ts
  tests/api/scraper.test.ts

Commit: abc1234 — fix(scraper): only mark items ready when usable
```
