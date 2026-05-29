---
name: mstack-init
description: |
  Bootstrap a project for mstack. Creates docs/plans/, .mstack/ with
  config and gitignore entries, optionally detects health tools and
  appends them to CLAUDE.md. Idempotent — safe to call repeatedly.

  Called automatically by mstack-plan-multi, mstack-plan-doctor,
  mstack-run, and mstack-status when .mstack/ doesn't exist. Also
  callable directly to set up a project explicitly.
argument-hint: "[--with-claude-md]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

You bootstrap a project for mstack. This is idempotent — running it on
an already-initialized project does nothing harmful.

User input (optional):

```
$ARGUMENTS
```

## Step 1 — Resolve paths and check state

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
```

Check if already initialized:

```bash
[ -d "$REPO_ROOT/.mstack" ] && echo "ALREADY_INITIALIZED" || echo "NEEDS_INIT"
```

If `ALREADY_INITIALIZED` and the user didn't invoke this skill directly
(i.e., called from another skill's auto-init guard), exit silently.

If `ALREADY_INITIALIZED` and invoked directly, show the current state
and offer to reinitialize.

## Step 2 — Run bootstrap

```bash
bash "$SKILL_DIR/scripts/init.sh" bootstrap
```

If the user passed `--with-claude-md`:

```bash
bash "$SKILL_DIR/scripts/init.sh" bootstrap --with-claude-md
```

This creates:
- `docs/plans/` (or detects existing `plans/`)
- `.mstack/` directory
- `.mstack/config.json` with defaults
- `.mstack/` and `.mstack-*` added to `.gitignore`
- (Optional) `## Health Stack` section appended to CLAUDE.md

## Step 3 — First-run guidance

If this is a fresh init (not already initialized), print:

```
mstack is ready. Three commands to know:

  /mstack-plan-multi "your goal"     Decompose a goal into ordered plans
  /mstack-plan-doctor                Validate and review the backlog
  /goal all pending mstack plans are done or failed   Execute autonomously

Everything else (health checks, code review, debugging, crash recovery)
runs automatically inside the loop. You don't need to call those directly.

Optional: run /mstack-config show to see project settings.
```

## Auto-init guard (for other skills to use)

Other mstack skills should include this guard near the top of their
execution flow:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

This ensures every mstack skill checks for updates (cached, once per hour)
and works on first use without requiring the user to run init manually.
