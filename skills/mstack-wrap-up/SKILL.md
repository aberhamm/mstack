---
name: mstack-wrap-up
description: |
  End-of-session harvest. Before a session ends, mine it for the things only
  this session knows: scaffolding that should now be deleted, work that
  obsoleted something, docs its changes made wrong, learnings never written
  down, decisions a future session would re-litigate. Runs a session-recall
  pass plus a delegated mechanical scan of the working tree, merges them into
  one findings list, and renders a verdict (cleared to close / not cleared).
  Report-only: it never deletes, commits, pushes, or touches plan review state.
triggers:
  - wrap up the session
  - end-of-session review
  - harvest this session before we close
  - anything left over before I close this
  - session cleanup check
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - Agent
---

# Wrap Up

User input (optional):

```
$ARGUMENTS
```

## Three roles, one axis

Three skills sit at the end of a session. They are not interchangeable, and
the axis that separates them is **terminal vs continuation**:

- **`mstack-wrap-up` (this skill) — the harvest, and the front door.** It
  mines the session's context *for the repository*, while that context still
  exists. Terminal: it assumes the knowledge is about to be lost. It is also
  the conductor — it renders the verdict and, once plan 042 lands, offers the
  routes onward.
- **`mstack-handoff` — the continuation.** It packages context *for the next
  session*. Offer it when follow-on work exists; it is the opposite end of the
  axis from wrap-up, not a substitute for it.
- **`cctrl-session-end` — the close.** External skill, owned by cctrl. It ends
  the session. Wrap-up never does this itself.

Wrap-up produces a **verdict, not a close**.

## Verdict, not close

The product of this skill is a verdict:

- `✅ cleared to close` — the harvest found nothing that must be dealt with
  first, or everything found is acknowledged and inert.
- `⚠️ not cleared` — followed by concrete reasons (never a vague "some issues").

The verdict is **honest but never blocking**. It has no gate semantics. It does
not interfere with the plan 034–039 completion-enforcement family, and it does
not act as a fleet-manager close gate. `⚠️ not cleared` is information for the
user, not a refusal. Nobody is stopped from closing anything.

Without cctrl, **the verdict IS the ending** — the skill renders it and stops.

## Resolve helpers

At the start of any invocation, resolve the two deterministic helpers through
the standard four-path skill-base loop:

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -x "${_skill_base}/mstack-run/scripts/handoff.sh" ] && { HANDOFF_HELPER="${_skill_base}/mstack-run/scripts/handoff.sh"; break; }
done
[ -n "${HANDOFF_HELPER:-}" ] || HANDOFF_HELPER="$(git rev-parse --show-toplevel 2>/dev/null)/skills/mstack-run/scripts/handoff.sh"
# A missing handoff.sh degrades to exactly the available=false path — never a
# raw shell error, never a probe the flow cannot interpret.
[ -x "$HANDOFF_HELPER" ] || HANDOFF_HELPER=""

for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -x "${_skill_base}/mstack-run/scripts/wrapup-scan.sh" ] && { SCAN_HELPER="${_skill_base}/mstack-run/scripts/wrapup-scan.sh"; break; }
done
[ -n "${SCAN_HELPER:-}" ] || SCAN_HELPER="$(git rev-parse --show-toplevel 2>/dev/null)/skills/mstack-run/scripts/wrapup-scan.sh"
[ -x "$SCAN_HELPER" ] || echo "mstack-wrap-up: wrapup-scan helper not found — mechanical check unavailable, recall list only"
```

Neither helper is fatal when absent. A missing `wrapup-scan.sh` means Pass A
still runs and the output is labeled recall-only. A missing `handoff.sh` leaves
`HANDOFF_HELPER` empty, which is treated as exactly `available=false` below —
skip the probe entirely rather than invoking a path that does not exist.

## Mode detection

- **Terminal mode (default).** The session is ending. Both passes run, then the
  verdict.
- **Mid-session mode.** The invocation says "keep working", "mid-session",
  "harvest but don't stop", or similar. Both passes run identically, but the
  **verdict ending is skipped** and **no ending questions are asked**. Close
  with `Continuing — harvest recorded.` and nothing else.

## cctrl probe (silent when absent)

Probe once, before anything is rendered (skip the probe when `$HANDOFF_HELPER`
is empty — that case is `available=false`):

```bash
[ -n "$HANDOFF_HELPER" ] && bash "$HANDOFF_HELPER" cctrl-status || echo "available=false"
```

This inherits `mstack-handoff`'s doctrine **verbatim**. If the first line is
`available=false`, ignore cctrl entirely — do not mention cctrl, spawning, or
session-closing anywhere in the flow. **The user is none the wiser.** If it is
`available=true`, capture `session=`, `target=`, and `can_close_self=` for
later.

### "close": state vs action

These are different things and the distinction is load-bearing:

- **State.** The verdict phrase `✅ cleared to close` is an *assessment of the
  session's state*. It is always allowed — with or without cctrl. It says
  nothing about who closes anything or how.
- **Action.** An *offer, question, or command to close the session* is an
  action. `available=false` forbids exactly this, and nothing else.

So a no-cctrl session still ends with `✅ cleared to close`. It just never sees
the word "close" used as something on offer.

This plan (041) contains **no close offer at all** — 042 adds it. The doctrine
line for it is written now so 042 slots in without redesign: with
`available=true` but `can_close_self=false`, the session is not closable from
within (`handoff.sh` mirrors cctrl's `.can_close_self` field, defaulting false;
fleet-managed sessions are one example, not the definition). **Gate purely on
the field**: render the verdict and wait. Never infer closability from anything
else.

## Pass A — session recall (first, inline, and the actual product)

**Recall is the product; the greps are the floor.** The mechanical scan can
only find what a regex can see. Everything valuable at the end of a session —
that this file was scaffolding, that this doc is now wrong, that the user ruled
something out an hour ago — lives *only* in the session's own memory and
evaporates when the session does. So Pass A runs **first**, inline, in the main
agent. Do not delegate it; a subagent has no session memory to recall.

Walk all five categories, in order. For each, state findings or state that
there are none — **say "nothing in this category" rather than silently skipping
it**, so a miss is visible as a miss (but see **Compact empty state** below,
which collapses the all-empty case).

1. **Scaffolding created that should now be deleted.** Test fixtures, probe
   scripts, sample data, a throwaway harness, a scratch file that made it into
   the repo. What did I create *to get somewhere* rather than *as the product*?
2. **Things obsoleted but not deleted.** The old implementation the new one
   replaced, a now-unused helper, a config entry for a path that no longer
   exists, a dead code branch. What did this session's work make redundant?
3. **Docs and comments the session's changes made wrong.** A README describing
   the old flow, a code comment describing the old contract, an AGENTS.md rule
   that the change invalidated. Not "docs that could be better" — docs that are
   now *false*.
4. **Learnings worth persisting that were never written down.** A pitfall hit
   and worked around, a convention discovered the hard way, a non-obvious
   constraint. If a future session would waste an hour rediscovering it, it
   belongs somewhere durable.
5. **User decisions made this session that a future session might
   re-litigate.** An approach the user rejected, a tradeoff explicitly chosen,
   a "no, do it this way" that lives nowhere but the transcript. These get
   re-argued from scratch if they are not captured.

For each finding, record: **what**, **where**, and a **suggested destination**
(where it should go — a deletion, a doc, a learnings entry, an AGENTS.md rule).
In 041 the destination is printed as a suggestion only; 042 turns destinations
into live routes.

## Pass B — mechanical scan (delegated)

Delegate to **one subagent** via the Agent tool. Its entire job is to run
`wrapup-scan.sh` for each in-scope repo and hand back what it printed.

The subagent prompt must say, in substance:

> Resolve `wrapup-scan.sh` through the four-path skill-base loop
> (`~/.config/skillshare/skills`, `~/.agents/skills`, `~/.codex/skills`,
> `~/.claude/skills`; fall back to `$(git rev-parse --show-toplevel)/skills/`).
> Run `bash "$SCAN_HELPER" <repo> [<repo> ...]` with exactly the repos I name —
> do not add repos, do not guess at repos, do not scan `$PWD` if I did not name
> it.
>
> Return the **raw structured findings verbatim**. Per repo the script emits a
> `repo=<abs path>` header, then five `section=<name> count=<n>` lines in a
> fixed order (`uncommitted`, `artifacts`, `stashes`, `merged-branches`,
> `unpushed`) with each entry on its own two-space-indented raw line, then
> `findings=<N>`. `merged-branches` and `unpushed` carry a `local-refs-only`
> marker (the script never fetches). Preserve all of it.
>
> You may add **mechanical annotations only** — e.g. which artifact pattern a
> basename matched, an entry's file size or mtime. You must **not** classify
> anything as litter, deliberate, expected, or safe to delete. You do not have
> the session memory required to make that call.
>
> Exit codes: `0` = scan completed (findings are data, not an error); `29` =
> some target was not a git repository — report which one, and never present it
> as clean; `1` = a repo's git status was unreadable. A repo block that emits
> `error=git-status-unreadable` has no `findings=` line: report it as UNKNOWN.
> **A nonzero exit never means "clean."** Report the exit code back to me.

### Multi-repo scope: explicit only

- **Default scope = the repo containing `$PWD`.** Nothing else.
- Additional repos are scanned **only** when (a) they are named in the
  invocation, or (b) the main agent is **certain from its own session memory**
  that it edited them. There is no durable touched-path log, so the subagent
  must never infer scope — it scans exactly the list it was handed.
- A repo the recall pass merely *suspects* was touched is a **report-only
  mention** ("possibly also touched: `<path>` — not scanned"), never a silent
  scan.
- The findings header **states exactly which repos were scanned**.

### Non-git targets fail loud

If a target is not a git repository (exit 29, e.g. `~/inference`), say so
plainly:

```
mechanical check unavailable: <path> is not a git repository — recall list only
```

Never render a non-git or unreadable target as "clean". The absence of a
mechanical result is an unknown, not an all-clear.

## Merge and classify (main agent)

Merge Pass A and Pass B into **one findings list**. **Classification happens
here, in the main agent, never in the subagent** — only the main agent knows
whether `debug-probe.sh` is scaffolding it created forty minutes ago or a file
the user has been maintaining for a year.

Classify each merged finding:

- **litter** — created by this session as a means, not an end. Safe to propose
  for removal.
- **deliberate** — the user's, or the product. Leave it alone; do not propose
  removing it.
- **unknown** — cannot tell. Say so explicitly and let the user decide. Never
  resolve an unknown by guessing.

Each finding renders as: **what** — **where** — **suggested destination**.

### Report-only boundary (041)

This layer **routes nothing and asks nothing**. It prints findings and the
verdict. The write-facing guardrails below are stated in full as
forward-doctrine for plan 042; in 041 they are inert, because this skill's
`allowed-tools` omits `Edit` and `Write` — it cannot write even if it wanted to.

Nothing is lost by ending here. **The findings are re-derivable**: re-running
wrap-up in a later session re-runs the mechanical scan, and the recall pass is
worth re-running anyway. So closing a session before 042 exists costs nothing
that this skill was holding.

### Compact empty state (a requirement, not a nicety)

A clean session ends in **~3 lines and zero questions**:

```
Recall: nothing in any category
Scan: clean (/Users/me/dev/myrepo)
✅ cleared to close
```

When every recall category is empty, collapse them to that **single line** —
do not print five empty category paragraphs. Five empty paragraphs is a **spec
violation, not thoroughness**. Expand a category only when it has something in
it. If some categories have findings and others do not, print the ones with
findings and note the empty ones compactly ("nothing in this category" on one
line each, or omitted from an already-long report — never padded out).

## Verdict (terminal mode only)

Render last:

```
✅ cleared to close
```

or

```
⚠️ not cleared
  - <concrete reason>
  - <concrete reason>
```

Reasons must be concrete and actionable ("3 untracked artifacts from this
session's debugging are unclassified", "the change to `foo.sh` makes the README
flow section false"). "Some things need attention" is not a reason.

Honest but never blocking: `⚠️ not cleared` reports; it never refuses, gates,
or stalls.

**Mid-session mode ends here differently**: skip the verdict block entirely,
ask nothing, and print `Continuing — harvest recorded.`

## Guardrails

Each of these is a rule, not a preference.

- **Never `git add .`** — and never `git add -A`, never `git commit -a`.
  Staging is explicit file lists with explicit approval, always. A wrap-up that
  sweeps unrelated work into a commit is worse than no wrap-up.
- **Report unpushed commits, but NEVER push.** The `unpushed` scan section is
  informational. Pushing is the user's call, in the user's own command.
- **NEVER touch plan review state.** Do not edit a plan's `status`,
  `needs-review`, `review-required`, or `reviews` fields, and do not mark a
  plan done. This is plan-035 doctrine: only the named review skills write
  review records or clear gates, and wrap-up is not one of them. The most this
  skill may ever do is *report*: "plan NNN looks near-complete."
- **Multi-repo needs an explicit repo list**, and the output **says which repos
  were checked**. Never scan a repo the user did not name and the session did
  not certainly touch; never let an unscanned repo pass as scanned.
- **Non-git targets fail loud**, never "clean": "mechanical check unavailable,
  recall list only".
- **Doc writes are propose-by-default.** Show the proposed edit, get approval,
  then write. (Forward-doctrine: inert in 041, which has no write tools.)

## What NOT to do

- Don't skip Pass A because Pass B found nothing. The scan is the floor, not
  the ceiling — a clean `git status` says nothing about the doc your change
  just made wrong.
- Don't delegate the recall pass. A subagent has no session memory; delegating
  Pass A produces confident, empty output.
- Don't let the subagent classify. Raw findings and mechanical annotations
  only; litter-vs-deliberate is a main-agent call.
- Don't pad the empty state. Three lines is the correct output for a clean
  session.
- Don't turn the verdict into a gate. `⚠️ not cleared` is a report. The user
  closes whenever they want.
- Don't delete anything. This skill reports; the user decides.
