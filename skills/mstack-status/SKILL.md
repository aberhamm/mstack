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
modify files. It only reads and reports.

User input (optional, a plan id like `042` or a name/slug/title fragment
like `my-feature`):

```
$ARGUMENTS
```

## Auto-init

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Scripts

All dashboard logic lives in `status.sh`. Resolve the scripts directory:

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
| `bash "$SCRIPTS_DIR/status.sh" dashboard` | Full status dashboard |
| `bash "$SCRIPTS_DIR/status.sh" plan <id\|name>` | Detailed status for one plan |

## Default mode (no argument or dashboard)

Run `bash "$SCRIPTS_DIR/status.sh" dashboard` and present the output
directly to the user. The script produces:

```
MSTACK STATUS
=============
Project: <project name>
Branch:  <current branch>
Date:    <today>
Last activity: 12 days ago (2026-05-18)

BACKLOG
  Done:        5 plans
  Failed:      1 plan
  Pending:     3 plans
  Next ready:  044: Add rate limiting to API endpoints

  Recent completions:
    043: Refactor user service  done   2026-05-19
    042: Fix scraper bug  done   2026-05-18

  Open gates (review required but not recorded):
    047: Add dark mode  blocked: review required but not recorded (not completable: review 'eng' has no passing record)

  Approved but uncommitted (commit the recorded approval):
    049: Add SSO login  approved but uncommitted: commit the approval (git add <plan> && git commit)

HEALTH TREND
  Latest: 9.1/10
  Trend:  9.4 → 8.8 → 9.1

STASHED
  3 threads (oldest: 12 days)
    "Auth token refresh strategy" (May 24)
    "Notification architecture" (May 21)
    "Edge function migration" (May 19)

REVIEWS
  Last review: 042: Fix scraper bug — 3 findings, 2 fixed

RECENTLY SHIPPED
  3fca88d feat: rewrite README for solo-dev positioning (12 days ago)
  f04c36a refactor: rename plan-backlog to plan-multi (12 days ago)
  10e4c15 fix: add worktree cleanup to mstack-run startup (13 days ago)

LEARNINGS
  7 patterns accumulated
  Recent:
    orm-upsert: this ORM doesn't support upsert on partitioned tables
    test-isolation: always reset DB state between integration tests
    api-validation: zod schemas must match OpenAPI spec or client breaks

SESSION
  Plans this session: 3 completed, 1 failed
  User notes:         2 carried forward
```

If the script exits with code 2 (no plans directory), tell the user:
"No plans directory found. Run /mstack-plan-multi to create one."

**Open gates** section (plan 036): for each `pending`/`blocked` plan that
declares a review requirement (`needs-review` non-`none` or `review-required`
non-`none`), `status.sh` runs `review-gate.sh assert-completable <plan>` and
lists the plan if the gate is still open — i.e. `mstack-run` Step 7a would
refuse to mark it done right now. This surfaces the same fail-closed check
Step 7a runs at completion time, so an open gate is visible before the worker
ever gets there, not discovered as a completion failure. The section is
omitted when no plan has an open gate. The check is bounded: plans without a
declared review requirement never spawn `review-gate.sh` at all (a cheap
frontmatter pre-filter skips them), so this stays one bounded subprocess per
flagged plan, not a quadratic pass over the backlog.

**Approved but uncommitted** section (plan 037): for every `pending`/
`blocked`/`in-progress` plan that carries >=1 recorded `reviews:` verdict
(the "approved" definition — not "gate reads cleared"), `status.sh` runs
`review-gate.sh assert-committed <plan>` and lists the plan if the check
fails, i.e. that plan's approval is sitting uncommitted in the working tree
right now. This heals pre-existing dirty approvals too, not just ones
recorded in the current session — the check re-runs every time `/mstack-status`
is invoked. This is read-only: `status.sh` never commits anything itself;
fixing a listed plan means running `git add <plan> && git commit` (or
re-running `/mstack-plan-doctor`, whose Step 0 audit offers to do it for
you). The section is omitted when no plan has this problem. The check is
bounded the same way as open gates: plans with no recorded `reviews:` entry
at all never spawn `review-gate.sh` (a cheap frontmatter pre-filter skips
them), so this stays one bounded subprocess per flagged plan.

**Review audit** section (plan 038): `status.sh` runs `review-gate.sh audit`
once (a single bounded scan over all `done`/archived plans) and lists any plan
whose `review-required` types lack a passing `reviews:` record. Unlike the
open-gate and approved-but-uncommitted checks — which look at plans still in
flight — this is the **retroactive backstop**: it catches completions made
with `git commit --no-verify` (which skips the write-time hook) or by
out-of-band edits, so a bypass leaves an evidence trail the next
`/mstack-status` surfaces. The section is omitted when the audit is clean
(exit 0, no output). This is read-only; healing an offender means running the
named review skill to record the missing verdict.

## Plan detail view

If the user passes a plan ID or a name/slug/title fragment as argument
(e.g., `/mstack-status 042` or `/mstack-status my-feature`):

Run `bash "$SCRIPTS_DIR/status.sh" plan <arg>` and present the output. The
script resolves a non-numeric argument via the plan-031 resolver
(`resolve_plan_ref`), so a name/slug/title fragment works the same as an id.
Ambiguous names exit nonzero with the candidate list printed; report that to
the user rather than guessing a plan. For example, `status.sh plan 042`
produces:

```
PLAN 042: Fix scraper empty payload bug
========================================
Status:     done
Completed:  2026-05-18
Blocked by: none

File: docs/plans/042-fix-scraper-bug.md
```
