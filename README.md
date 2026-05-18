# mstack

Plan-driven autonomous workflow skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Write plans. Let the AI work the backlog.

## What is this?

mstack is a set of skills that turn Claude Code into an autonomous backlog worker. You describe what you want to build, mstack decomposes it into ordered plan files, validates them, and executes them one at a time — committing working increments directly to `main`. No feature branches, no PRs, no babysitting.

The workflow:

```
You describe a goal
  → /mstack-plan-initiate decomposes it into plans
    → /mstack-plan-doctor validates the plans
      → /mstack-work-next-plan executes them autonomously
        → /mstack-learnings remembers what worked
```

## Skills

| Skill | What it does |
|---|---|
| **mstack-plan-initiate** | Takes a high-level goal and produces an ordered backlog of dependency-wired plan files |
| **mstack-new-plan** | Scaffolds a single plan file from a one-line title |
| **mstack-plan-doctor** | Validates plan files for format, gaps, and consistency; runs pending reviews |
| **mstack-work-next-plan** | Picks the next unblocked plan, implements it, runs verification, and commits |
| **mstack-learnings** | Self-healing knowledge base — learns from executions and applies to future plans |
| **mstack-simplify-code** | Reviews changed code for reuse and quality, then fixes issues |
| **mstack-changelog** | Syncs CHANGELOG.md with git history in Keep a Changelog format |
| **mstack-handoff** | Outputs a structured handoff summary so a fresh session can resume cleanly |

## Install

### With [skillshare](https://github.com/anthropics/skillshare)

```bash
skillshare install aberhamm/mstack
```

### Manual

Copy the `skills/` directory into your Claude Code skills location:

```bash
cp -r skills/mstack-* ~/.claude/skills/
```

## Usage

### Architect a backlog from a goal

```
/mstack-plan-initiate Add user authentication with email/password and OAuth
```

This produces numbered plan files in `docs/plans/` (or `plans/`), each with frontmatter specifying dependencies, status, and implementation notes.

### Validate plans before execution

```
/mstack-plan-doctor
```

Audits all plans for format issues, missing dependencies, and gaps. Can also target a single plan by id.

### Execute the next plan

```
/mstack-work-next-plan
```

Picks the highest-priority unblocked plan, implements it, runs your project's verification gate (typecheck, lint, tests), and commits. Never pushes — you review `git log -p` and push when ready.

### Run the full backlog autonomously

```
/loop /mstack-work-next-plan
```

Self-paced autonomous execution. Works through the backlog one plan at a time, committing each as it completes.

### Scaffold a single plan

```
/mstack-new-plan Add rate limiting to the API -- depends-on 003,004
```

### Review and manage learnings

```
/mstack-learnings list
/mstack-learnings search "database migrations"
/mstack-learnings prune
```

### Update the changelog

```
/mstack-changelog
```

### Hand off to a new session

```
/mstack-handoff
```

## Plan file format

Plans live in `docs/plans/` (or `plans/`) as numbered markdown files:

```
docs/plans/
  001-setup-database-schema.md
  002-add-user-model.md
  003-implement-auth-endpoints.md
  ...
```

Each plan has YAML frontmatter:

```yaml
---
id: 3
title: Implement auth endpoints
status: pending        # pending | in-progress | done | failed
depends-on: [1, 2]
allows-migrations: false
---
```

The body contains implementation context — what to build, key decisions, edge cases, and acceptance criteria.

## Design principles

- **Never push to remote.** The user pushes manually after reviewing.
- **Never bypass verification.** If checks fail, the plan is marked `failed` — never commit broken code to `main`.
- **Each plan is independently shippable.** No plan leaves the codebase in a broken intermediate state.
- **Learn from execution.** Patterns and pitfalls are captured automatically and applied to future plans.
- **Right-sized plans.** Each plan targets roughly 1-3 hours of focused human work.

## License

MIT
