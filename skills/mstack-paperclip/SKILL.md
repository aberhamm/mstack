---
name: mstack-paperclip
description: Native Paperclip tracking compatibility entrypoint for existing desktop and CLI sessions.
argument-hint: "[connect | status | reconnect | disable | reconcile]"
allowed-tools: Bash Read Write
---

## Runtime paths

Set `MSTACK_SKILL_FILE` to the absolute path of this loaded `SKILL.md`,
supplied by the harness. Repeat this bootstrap in each fresh Bash invocation:

```bash
MSTACK_SKILL_FILE="/absolute/path/to/mstack-paperclip/SKILL.md"
MSTACK_RESOLVER="$(cd "$(dirname "$MSTACK_SKILL_FILE")/../mstack-run/scripts" && pwd)/install-paths.sh"
source "$MSTACK_RESOLVER"
SKILL_DIR="$(skill_dir mstack-run)" || exit 1
mstack_update_check
```

Use mstack's shared configuration and lifecycle helpers. Codex and Claude desktop
or CLI remain execution clients; Paperclip holds the project dashboard and human
session reports. Never dispatch or assign a container agent.

Connect, reconnect and disable route to **mstack-config paperclip**. Status uses
**mstack-status** for local backlog and pending/conflicting delivery; an explicit
connectivity check uses **mstack-config paperclip status**. Reconcile runs the
mstack-run script `paperclip_lifecycle.sh reconcile --repo PATH --limit 10`.
Use `$SKILL_DIR/scripts/paperclip_lifecycle.sh` from the loaded installation.
Disabled bindings exit before Python, credential discovery or network calls.

For plan work, invoke normal authoring/run/handoff/wrap-up skills: they now report
at their authoritative boundaries. Do not recreate the standalone transport or
run its old list/show/start/update commands. Existing imported tasks are adopted
by their exact source markers, and independent TODO records remain visible.
Never infer local readiness or completion from remote issue status. Report queued
work as pending, ownership/manual-state changes as conflicts, and resolve them
explicitly after inspection. See the installed mstack `docs/paperclip-migration.md`
for adoption, source ownership and rollback. Credentials remain in each machine's
official board store; never print, copy between machines, or include them in notes.
