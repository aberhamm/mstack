# mstack Agent Guide

This repository is the source for MStack, a plan-driven autonomous workflow
framework distributed as agent skills.

## Canonical Instructions

- Keep shared project instructions in `AGENTS.md`.
- Keep `CLAUDE.md` as a thin compatibility shim that imports this file with
  `@AGENTS.md`.
- Do not duplicate long-lived workflow rules across both files.
- When adding agent-specific notes, keep the shared rule here and put only the
  agent-specific exception in that agent's file.

## Repository Shape

- `skills/mstack-*` contains the skill source directories.
- `skills/mstack-run/scripts/` contains deterministic shell helpers used by
  multiple skills.
- `skills/mstack-run/references/` contains long-form references loaded on
  demand by `mstack-run`.
- `docs/plans/` contains this repo's implementation plans; archived completed
  plans live under `docs/plans/archive/`.
- `setup` links MStack skills into the parent skill directory for legacy
  Claude/Skillshare installs.

## Skill Routing

When a user request matches an MStack workflow, use the matching skill:

- "create a plan for...", "plan out...", "break this down" ->
  `mstack-plan-multi`
- "validate plans", "check the backlog", "are plans ready" ->
  `mstack-plan-doctor`
- "review the backlog", "reprioritize", "reorder plans", "groom",
  "triage" -> `mstack-backlog`
- "run the plans", "execute the backlog", "start the loop" -> `mstack-run`
- "where are we", "what's next", "backlog status" -> `mstack-status`
- "configure mstack", "change health weights" -> `mstack-config`
- "show learnings", "what patterns" -> `mstack-learned-patterns`
- "stash this", "save for later", "come back to this", "not ready to plan" ->
  `mstack-stash`
- "handoff", "save session state" -> `mstack-handoff`
- "resume from handoff", "load handoff", "pick up where I left off" ->
  `mstack-handoff` in resume mode

## Compatibility Rules

- Treat `AGENTS.md` as the primary project guidance file for Codex.
- Treat `CLAUDE.md` as a compatibility import file for Claude Code.
- When skills need to read project guidance, support both `AGENTS.md` and
  `CLAUDE.md`.
- When skills need to locate installed MStack assets, prefer path resolution
  that works across Skillshare, Codex, and Claude:
  `~/.config/skillshare/skills`, `~/.agents/skills`, `~/.codex/skills`, then
  `~/.claude/skills`.
- Prefer agent-neutral wording in shared MStack instructions. Call out
  Claude-only or Codex-only behavior explicitly when the behavior differs.

## Development Commands

Run focused checks after changing shell helpers:

```bash
bash -n skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
shellcheck skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
```

Useful smoke checks:

```bash
bash skills/mstack-run/scripts/config.sh show
bash skills/mstack-run/scripts/status.sh
bash skills/mstack-run/scripts/pick-next.sh
```

`pick-next.sh` exits with code `10` when all plans are done; that is expected
for an empty backlog.

## Editing Expectations

- Keep changes scoped to the relevant skill, script, or reference.
- Do not rewrite archived plans unless the task is explicitly archival cleanup.
- Do not revert unrelated local changes. This repo is often dirty during
  active MStack work.
- Use deterministic shell scripts for behavior that should survive across
  agents; use skill prose for workflow judgment.
