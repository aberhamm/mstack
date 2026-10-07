---
name: mstack-paperclip
description: Native Paperclip tracking compatibility entrypoint for existing desktop and CLI sessions.
argument-hint: "[connect | status | reconnect | disable | reconcile]"
allowed-tools:
  - Bash
  - Read
  - Write
---

Use mstack's shared configuration and lifecycle helpers. Codex and Claude desktop
or CLI remain execution clients; Paperclip holds the project dashboard and human
session reports. Never dispatch or assign a container agent.

Connect, reconnect and disable route to **mstack-config paperclip**. Status uses
**mstack-status** for local backlog and pending/conflicting delivery; an explicit
connectivity check uses **mstack-config paperclip status**. Reconcile runs the
mstack-run script `paperclip_lifecycle.sh reconcile --repo PATH --limit 10`.
Resolve mstack-run via the standard Skillshare, agents, Codex, Claude skill lookup.
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
