---
id: 030
title: Optional cctrl spawn handoff (save + launch fresh session, confirm before close)
status: done
blocked-by: []
priority:
goal: handoff-cctrl-spawn
allows-migrations: false
needs-review: none
created: 2026-06-26
---

> Retro-written plan: the implementation landed in the same commit that adds
> this file. Captured after the fact so the change has a paper trail consistent
> with the rest of the backlog. The one outstanding item is a live end-to-end
> test of `spawn`/`close-self` (see Verification → manual).

## Requirements

`mstack-handoff` has two delivery modes: print the handoff in chat, or save a
checkpoint under `.mstack/handoffs/` for "resume from handoff" in a new session.
Both leave the human to manually open the next session and paste/resume.

When the handoff runs inside a **cctrl-managed session** (the user's own
`dev/cctrl` agent-session controller), the framework can collapse the
"`/clear` → open new session → resume" dance into one step: write the
checkpoint, spawn a fresh detached session seeded to load it, and — only after
that succeeds and only with explicit confirmation — close the current session.

This must be **strictly optional and self-detecting**. When cctrl is absent the
feature is invisible: no new prompt, no mention of cctrl, identical behavior to
today. It must NOT auto-close the current session, and must never close it
before the new session is verified up.

**Acceptance criteria:**

- [ ] Detection is free and silent: a `cctrl-status` helper reports
      `available=false` when `cctrl` is not on PATH or the process is not inside
      a cctrl-managed session (`$CCTRL_SESSION_NAME` unset). The skill offers the
      spawn mode ONLY on `available=true`; on `false` it never mentions cctrl,
      spawning, or session-closing anywhere in the flow.
- [ ] On `available=true`, `cctrl-status` also surfaces the current session id,
      target, agent, cwd, and `can_close_self` so the skill can show the user
      which session would be closed.
- [ ] A `spawn <short-summary>` helper resolves the checkpoint (failing early on
      a bad summary, WITHOUT deleting it), launches a detached cctrl session
      seeded with `resume from handoff <short-summary>`, then VALIDATES that a
      new managed session actually appeared before reporting success.
- [ ] Validation is robust to output-format drift: it diffs the managed-session
      name list before vs after the launch, not parsed `start` stdout.
- [ ] `spawn` prints `spawn_ok=true` + `new_session` + `attach_command` on
      success, or `spawn_ok=false` + a reason on failure. On failure the current
      session is left untouched and the user gets the manual resume command.
- [ ] The spawned agent loads the handoff and WAITS; it does not start work on
      its own (preserves the handoff's human-in-the-loop checkpoint).
- [ ] Closing the current session is a SEPARATE, confirmed step, reachable only
      after a verified `spawn_ok=true`. The confirmation prompt shows the current
      tmux session id so the user can verify it is the right one to close.
- [ ] A `close-self [grace]` helper closes the current session via cctrl's
      built-in grace period (so the calling turn finishes before the pane dies).
- [ ] No new skill tools required (`Bash` already covers running cctrl); no new
      runtime dependency for non-cctrl users.

## Design

Keep deterministic behavior in the shared shell helper and judgment/interaction
in skill prose, per the repo's split.

**`skills/mstack-run/scripts/handoff.sh`** gains three subcommands:

- `cctrl-status` — `cctrl_available()` gates on `command -v cctrl` AND a
  non-empty `$CCTRL_SESSION_NAME` (the env var cctrl exports into every managed
  session — detection needs no subprocess for the negative case). On
  availability it enriches from `cctrl session current --json` (session, target,
  agent, cwd, `can_close_self`) with env-var fallback, emitting `key=value`
  lines. Returns `available=false` and exit 0 everywhere else.
- `spawn <short-summary>` — calls the existing `cmd_resolve` to confirm the
  checkpoint exists (no delete), derives the canonical summary, snapshots
  `cctrl session ls --json | jq '.[].name'` into a sorted baseline, runs
  `cctrl start <target> -d -m "resume from handoff <summary>"`, then polls
  (~8s) diffing the session-name list with `comm -13` until a new name appears.
  Reports `spawn_ok` + details.
- `close-self [grace]` — thin wrapper over `cctrl close [--in N]`.

All three degrade silently: `cctrl-status` is the only one the skill calls
unconditionally; `spawn`/`close-self` are only invoked after `available=true`.

**`skills/mstack-handoff/SKILL.md`**:

- Probe `cctrl-status` at the start of the delivery-mode step; capture
  `session=`/`target=` when available.
- Add a conditional third AskUserQuestion option, "Save + spawn fresh session",
  offered only on `available=true`.
- Add a "Spawn mode" section encoding the ordering: write checkpoint → `spawn`
  → on `spawn_ok=false` leave the session untouched and give the manual resume
  command → on `spawn_ok=true` report the new session + attach command → only
  then ask to close, showing the current session id → on yes `close-self`, on no
  leave it running. "Never close before `spawn_ok=true`; never close without
  explicit confirmation."
- Update the "After writing" branch and the frontmatter description.

**Out of scope:** bare-tmux support without cctrl (tmux alone has no
agent-launch/identity layer — reinventing cctrl); the `cctrl peer` mailbox
(wrong shape — it targets already-running peers, not a fresh baggage-free
session); auto-close without confirmation.

**Files changed:**

- `skills/mstack-run/scripts/handoff.sh` (3 subcommands + dispatch + usage)
- `skills/mstack-handoff/SKILL.md` (delivery mode, spawn flow, description)

## Tasks

1. Add `cctrl_available` + `cctrl_session_names` helpers and the `cctrl-status`
   subcommand to `handoff.sh`; register in dispatch + usage.
2. Add the `spawn` subcommand: resolve-without-delete, baseline/launch/poll-diff
   validation, `spawn_ok` reporting.
3. Add the `close-self` subcommand wrapping `cctrl close`.
4. SKILL.md: probe `cctrl-status`; add the conditional third delivery option.
5. SKILL.md: add the "Spawn mode" section (validate-before-close, confirm with
   session id shown, no auto-kill); update "After writing" + frontmatter.

## Verification

Checks:
- [cmd] bash -n skills/mstack-run/scripts/handoff.sh
- [cmd] shellcheck skills/mstack-run/scripts/handoff.sh
- [cmd] bash skills/mstack-run/scripts/handoff.sh self-test
- [cmd] bash skills/mstack-run/scripts/handoff.sh --help | grep -qE "cctrl-status"
- [cmd] bash skills/mstack-run/scripts/handoff.sh --help | grep -qE "^\s*spawn "
- [cmd] bash skills/mstack-run/scripts/handoff.sh --help | grep -qE "close-self"
- [cmd] grep -qE "cctrl-status\) shift; cmd_cctrl_status" skills/mstack-run/scripts/handoff.sh
- [cmd] grep -qE "spawn_ok=(true|false)" skills/mstack-run/scripts/handoff.sh
- [cmd] grep -qE "comm -13" skills/mstack-run/scripts/handoff.sh
- [cmd] grep -qi "Save + spawn fresh session" skills/mstack-handoff/SKILL.md
- [cmd] grep -qi "available=false" skills/mstack-handoff/SKILL.md
- [cmd] grep -qiE "spawn_ok=true" skills/mstack-handoff/SKILL.md
- [cmd] grep -qiE "show .*session id|current session id" skills/mstack-handoff/SKILL.md
- [manual] Live dry-run (2026-06-27, in an isolated scratch project with its own
  `@spawndryrun` shortcut): `spawn dryrun-test` returned `spawn_ok=true` with the
  correct `new_session` detected via the before/after session-name diff; the new
  detached session opened in the scratch dir with the seeded `resume from handoff
  dryrun-test` purpose. Session + shortcut + scratch dir cleaned up after. PASS.
- [inspection] `close-self` deliberately NOT live-fired (it closes the current
  session). Verified it maps to `cctrl close [--in N]`, whose grace period is
  documented in `cctrl --help`.
- [caveat] The spawned agent stalls at Claude Code's "trust this folder" first-run
  prompt when the target dir has never been opened before (observed in the
  scratch-dir test); it then never processes the seeded resume until trusted. Not
  a concern for the real flow (spawn target is an already-trusted repo like
  `@mstack`), but spawn should not be pointed at a never-opened directory.
