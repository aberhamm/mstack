---
name: mstack-wrap-up
description: |
  End-of-session harvest. Before a session ends, mine it for the things only
  this session knows: scaffolding that should now be deleted, work that
  obsoleted something, docs its changes made wrong, learnings never written
  down, decisions a future session would re-litigate. Runs a session-recall
  pass plus a delegated mechanical scan of the working tree, merges them into
  one findings list, routes each finding to an existing sink, and renders a
  verdict (cleared to close / not cleared). It never deletes, commits, pushes,
  or touches plan review state; repo/doc writes are propose-by-default.
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
  - AskUserQuestion
  - Skill
  - Write
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
  the conductor — it routes each finding to an existing sink and renders the
  verdict.
- **`mstack-handoff` — the continuation.** It packages context *for the next
  session*. Offer it when follow-on work exists; it is the opposite end of the
  axis from wrap-up, not a substitute for it.
- **`cctrl-session-end` — the close.** External skill, owned by cctrl. It ends
  the session. Wrap-up never closes on its own initiative; the only close it
  performs is `handoff.sh close-self` after an explicit user "yes" to the cctrl
  close offer (see **Ending**).

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

Wrap-up **never closes a session on its own initiative**. The one close it can
perform is the cctrl close offer in **Ending** — a `handoff.sh close-self` run
only after an explicit user "yes", and only when the probe says the session is
closable from within. Without cctrl, **the verdict is the ending**: the skill
renders it and stops (bar the single handoff-save question when the harvest
surfaced follow-on work — see **Ending**).

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
  "harvest but don't stop", or similar. Both passes run identically, and the
  **findings question(s) are still asked** — routing is just as useful
  mid-session. But the **verdict ending is skipped**, **no ending question is
  asked**, and **no close is ever offered**. Close with
  `Continuing — harvest recorded.` and nothing else.

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

The close offer lives in **Ending** below, and it fires only when the probe
reported `available=true` AND `can_close_self=true`. With `available=true` but
`can_close_self=false`, the session is not closable from within (`handoff.sh`
mirrors cctrl's `.can_close_self` field, defaulting false; fleet-managed
sessions are one example, not the definition). **Gate purely on the field**:
render the verdict and wait. Never infer closability from anything else.

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

For each finding, record: **what**, **where**, and a **destination** — the sink
it routes to, taken from the **Router** table below. The destination is not a
freeform suggestion; it is the row that finding matches.

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

Each finding renders as: **what** — **where** — **destination** (its router row).

### Routing boundary

Routing sends findings to **existing sinks**. It creates no new state directory
and no new artifact type, and it never widens what this skill may touch: the
guardrails at the bottom of this file bind every route. In particular, no route
may edit plan review state, `git add .`, or push — those are hard rules, not
defaults.

Nothing is lost by declining every route. **The findings are re-derivable**:
re-running wrap-up in a later session re-runs the mechanical scan, and the
recall pass is worth re-running anyway.

### Compact empty state (a requirement, not a nicety)

A clean session ends in **~3 lines and zero findings-questions** (a cctrl
session that is close-eligible still gets its one ending question — see
**Ending**; nothing else is asked):

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

## Router — finding type → sink

Every finding routes to an **existing** sink. These seven rows are the whole
table; there is no eighth destination and no new artifact type.

| Finding type | Sink | Real entry point |
|---|---|---|
| Unwritten learnings | `mstack-learned-patterns` | Skill `mstack-learned-patterns`, or its helper directly — `mstack-run/scripts/learnings.sh append '<json>'` (resolved through the same four-path skill-base loop used above; JSON fields `key`, `insight`, `type`, `evidence`, `confidence`, `refs`) |
| Shipped-but-unlogged changes | `mstack-changelog` | Skill `mstack-changelog` (no arguments — it discovers CHANGELOG files, diffs git history, and drafts entries for approval) |
| Docs made stale by the session | a **proposed edit** | No skill: render a diff/summary of the proposed edit; write only on approval (see **Doc-edit proposals** below) |
| User preferences/decisions worth persisting | host agent memory, else `mstack-learned-patterns` | See the operational rule below |
| Unfinished work with follow-on value | `mstack-handoff` | Skill `mstack-handoff`, checkpoint mode (see **The handoff route** below) |
| Ideas not ready to plan | `mstack-stash` | Skill `mstack-stash` with a quoted string — its save mode: `/mstack-stash "auth token strategy"` |
| Cleanup too big for now | `mstack-plan-new` | Skill `mstack-plan-new` with a one-line title: `/mstack-plan-new "delete the legacy probe harness"` |

**Host agent memory — the operational rule.** Route a preference/decision to
host agent memory **only when the RUNNING agent already has a documented
persistent-memory mechanism in its own instructions** (e.g. a Claude Code
session whose system prompt announces a memory directory). Never probe a
foreign agent's config directories to find out. When the running agent has no
such documented mechanism, **fall back to a learned-patterns entry** — the
agent-neutral store, per repo convention.

### Write policy: propose by default

Every sink that writes to the repo or to docs is **propose-by-default**: show
what would be written, get approval, then write.

**The single exception is `mstack-learned-patterns`**, which may write
unprompted — learnings are prunable and have a low blast radius. State it as
what it is: an exception. It is not the pattern other sinks follow.

### Doc-edit proposals never block the flow

Selecting a doc-edit finding does **not** open an approval prompt inside the
flow. It renders the **ready diff** in the final report, and the flow ends
without waiting on it. The user applies a proposal afterward in normal
conversation ("apply #2"), and the main agent performs the Edit then.

So: explicit approval before any write, and **zero in-flow approval prompts**.

### The handoff route

Invoke `mstack-handoff` in **checkpoint mode**. There is **no prefill API** —
do not invent one, and do not pass invented parameters. The follow-on items are
already in session context, and handoff's own content-gathering step (which
folds a session's open items into "Next step" / "Open questions") picks them up.

## Interaction budget (button-only)

The budget is: **0–2 FINDINGS questions, plus at most 1 ENDING question.** No
path exceeds **3 questions total**. Most runs ask 0–1.

Findings questions, by count of findings:

- **0 findings → ZERO findings-questions.** The ~3-line clean ending above.
- **1–4 findings → ONE multiSelect** listing the findings directly. Each label
  names the finding **and** its destination ("stale README section → propose
  edit"), so one question carries both "should we act" and "where it goes".
- **>4 findings → ONE triage question**: `Apply all` / `Pick` / `Report only`.
  - `Apply all` → apply each finding via its route, honoring propose-by-default.
    "Apply" means **start the route**, not skip approval: a proposed doc edit
    still shows its diff before anything is written.
  - `Pick` → spends the **second** findings-question: a multiSelect of the
    **top 4 findings by value**, with the remainder explicitly listed in the
    report as report-only.
  - `Report only` → route nothing; print the findings.

**Never a third findings-question.** AskUserQuestion caps at 4 options; that cap
is honored by **triage-then-top-4**, never by paginating through findings.

**Hosts without AskUserQuestion** ask the same questions as plain numbered
prose, in agent-neutral wording, under the **same budget arithmetic**. A reply
is a number/letter list — minimal typing is the floor, never a free-text essay.

### Route execution order

Routes execute **after** the findings question(s), never before. Among selected
routes, the **`mstack-handoff` route always runs LAST** — it transfers
interaction control, and wrap-up asks nothing after that transfer. Because of
that, the handoff route runs *after the verdict is rendered*, at the point where
the ending would otherwise be: it **takes the place of the ending question**
(see **Ending**). Every other selected route runs before the verdict.

### Budget boundary

The 0–2 budget binds **`mstack-wrap-up`'s own flow**. Once the user opts into a
routed skill (choosing the handoff, say), **that skill's own questions**
(delivery mode, WIP-commit, and so on) run under **its** rules — a
user-consented handover, not a budget violation. Wrap-up itself asks nothing
further after the transfer.

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
skip **Ending** below (no ending question, no close offer — the findings
question(s) already happened), and print `Continuing — harvest recorded.`

## Ending (terminal mode only)

**At most ONE ending question, ever** — the cctrl close offer or the no-cctrl
handoff-save question, never both. The ending question is **excluded from the
0–2 findings budget** (it is the ending, not a finding), which is why the
ceiling is 2 + 1 = 3 questions and never more.

**Dedup rule:** if an "unfinished work → `mstack-handoff`" finding was selected
and routed, that route **is** the ending — it runs here (last, per **Route
execution order**) and **no ending question is asked at all**. The handoff-save
question is skipped because the handoff already happened; the close offer is
skipped because wrap-up asks nothing after the transfer, and `mstack-handoff`'s
own cctrl mode already covers closing the session. **Never ask twice.**

### With cctrl (`available=true` AND `can_close_self=true`)

After the verdict — and only when no handoff route ran (dedup rule above) — ask
**one yes/no question**. It **shows the current session
id** (the `session=` value from `cctrl-status`) and **folds any warning into the
question itself** rather than printing a separate warning line:

```
2 commits unpushed — close session <session> anyway?   [ yes / no ]
```

- **Yes** → `bash "$HANDOFF_HELPER" close-self`.
- **No** → stop. Nothing else is asked.

### With cctrl but `can_close_self=false`

Verdict, then **wait**. No offer, no mention of closing as an action. Gate
**purely on the field** — never infer closability from anything else.

### Without cctrl (`available=false`, including a missing `handoff.sh`)

Closing is **never mentioned** as an action; the doctrine above holds unchanged.
The verdict STATE phrase `✅ cleared to close` is still fine — it is an
assessment, not an offer.

- **Follow-on work surfaced by the harvest** (and no handoff route already
  ran) → the ONE allowed ending question: **"save a handoff checkpoint before
  you quit?"** Yes → route into `mstack-handoff` checkpoint mode (per **The
  handoff route** above: no prefill parameters; the items travel via session
  context).
- **No follow-on work** → **no question**. Verdict only.

## Related skills

- `mstack-handoff` — the continuation; also the sink for the unfinished-work
  row and the no-cctrl ending question.
- `mstack-learned-patterns`, `mstack-changelog`, `mstack-stash`,
  `mstack-plan-new` — the routed sinks.
- `cctrl-session-end` — the close, owned by the external cctrl repo. **Seam
  note:** that skill invoking `/mstack-wrap-up` as a **soft dependency** (probe
  for it, silently skip when mstack is absent) is the other half of this
  design. It lives in the cctrl repo and is deliberately **not** part of this
  skill; documented here so the seam is visible from this side.

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
  then write. The proposal is rendered in the report and applied later on the
  user's word — never behind an in-flow approval prompt.
  `mstack-learned-patterns` is the single exception that may write unprompted.
- **NEVER close a session that `can_close_self=false`**, and never mention
  closing as an action when `available=false`. The close offer is gated purely
  on those `cctrl-status` fields.

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
- Don't delete anything. This skill proposes; the user decides.
- Don't ask a third findings-question. >4 findings is triage-then-top-4, never
  a second page of options.
- Don't ask an ending question after a handoff route already ran, and don't ask
  one at all in mid-session mode.
- Don't invent a prefill parameter for `mstack-handoff`. It has none.
- Don't block the flow on a doc-edit proposal. Render the diff and end.
