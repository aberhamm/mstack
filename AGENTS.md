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
- `.codex/agents/` contains Codex custom agent adapters for MStack worker and
  reviewer subagents.
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

## Plan Citation Convention

No agent-facing output emits a bare plan ID. Every citation of a plan —
in a printed progress line, a status dashboard, a blocked/crash message,
a learnings header, or a table row — renders `NNN: Title` (the plan's
zero-padded id, a colon, its frontmatter title). Use the `plan_label`
helper in `skills/mstack-run/scripts/lib.sh` (or an equivalent
already-known id/title pair) to build the string; never print a plan id
on its own and make the reader open the repo to learn what it is. When a
message lists several dependency ids (e.g. "blocked by 026"), render each
one as `026: Title`.

Machine identifiers are exempt and MUST stay bare — do not "helpfully"
rewrite them: git commit message subjects and bodies, the
`mstack/plan-${PLAN_ID}-done` git tag, machine-readable JSON fields
(e.g. `plan_id` in checkpoint or `.mstack/reviews/plan-*.json`), and
evidence path names (e.g. `.mstack/evidence/plan-032/`). These are parsed
by scripts or `git`, not read as prose; adding a title would break the
parser or the identifier's shape.

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
bin/mstack-codex-smoke
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
