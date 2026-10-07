---
name: mstack-handoff
description: |
  Handoff summary for session transitions. Modes: output in chat (paste
  into new session), save a handoff checkpoint to .mstack/handoffs/ (resume
  with "resume from handoff" in a new session), or, when running inside a
  cctrl-managed session, save + spawn a fresh detached session and optionally
  close the current one. Checkpoints are auto-deleted on resume and auto-pruned
  after 7 days. Also: "from codex" mode ("handoff from codex", "codex handoff
  <thread>") reconstructs a checkpoint from a Codex CLI rollout on disk when
  Codex itself cannot write its own handoff (e.g. out of credits).
  Not this skill if: you want to park an unresolved idea rather than continue
  the work (use /mstack-stash), or you want to harvest this session's knowledge
  into the repo first (use /mstack-wrap-up — its own ending can invoke this
  skill for you, with the harvest folded in). Handoff is the continuation end
  of that axis; it also works standalone, invoked directly, with no harvest.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - Write
---

## Update check

Before any other work, run the shared, cooldown-aware check:

```bash
for _base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_base}/mstack-run" ] || continue
  _mstack_run="$(cd "${_base}/mstack-run" && pwd -P)"
  _mstack_root="$(cd "$_mstack_run/../.." && pwd -P)"
  bash "$_mstack_root/bin/mstack-update-check" 2>/dev/null || true
  break
done
```

# Handoff

User input (optional):

```
$ARGUMENTS
```

## Mode detection

At the start of any invocation, resolve the deterministic helper:

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -x "${_skill_base}/mstack-run/scripts/handoff.sh" ] && { HANDOFF_HELPER="${_skill_base}/mstack-run/scripts/handoff.sh"; break; }
done
[ -n "${HANDOFF_HELPER:-}" ] || HANDOFF_HELPER="$(git rev-parse --show-toplevel 2>/dev/null)/skills/mstack-run/scripts/handoff.sh"
[ -x "$HANDOFF_HELPER" ] || { echo "mstack-handoff: handoff helper not found"; exit 1; }
```

If `$ARGUMENTS` contains "resume" (e.g., invoked via routing rule with args
"resume"), skip directly to the **Resume from handoff** section below. Do not
generate a new handoff.

If `$ARGUMENTS` contains "list" or "show", skip directly to **List handoff
checkpoints**. Do not generate a new handoff.

If `$ARGUMENTS` contains "codex" — as in "from codex", "codex handoff", or a
bare "codex <thread-id>" — and did not already match the "resume"/"list"
checks above, skip directly to **From Codex** below. (The resume/list
checks are evaluated first on purpose: a short-summary can itself contain
the word "codex", e.g. "resume from handoff codex-clip-agreement", and
that must still resume, not restart reconstruction.)

Otherwise, proceed with the normal handoff flow.

## List handoff checkpoints

This mode is implemented by `handoff.sh list`.

Use the helper for deterministic discovery:

```bash
bash "$HANDOFF_HELPER" prune
bash "$HANDOFF_HELPER" list
```

If the user asks for all projects, all repos, or all workspaces, run:

```bash
bash "$HANDOFF_HELPER" list --all-projects
```

All-projects mode scans the current git root plus `$HOME/_projects` and
`$HOME/dev/projects`, follows symlinked roots, deduplicates canonical paths,
and avoids `.git`, `node_modules`, `.pnpm`, and build-output directories.
The output includes checkpoint path, age, short summary, and the exact
`resume from handoff <short-summary>` command. Empty handoff directories are
reported separately from projects with no `.mstack/handoffs/` directory.

## From Codex

Use this mode when Codex itself cannot write its own handoff — most often
because it ran out of credits mid-session — and the only way to continue
its work is to reconstruct a checkpoint from the Codex rollout already on
disk. Triggered by "handoff from codex", "codex handoff <thread>",
"/mstack-handoff from codex [thread]", or the AGENTS.md routing entry.

This mode is read-only against Codex's own data: nothing is ever written
under `~/.codex`, and no checkpoint is written before step (c) below.

Resolve the extractor script the same way `$HANDOFF_HELPER` is resolved
above:

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -f "${_skill_base}/mstack-handoff/scripts/codex_threads.py" ] && { CODEX_THREADS="${_skill_base}/mstack-handoff/scripts/codex_threads.py"; break; }
done
[ -n "${CODEX_THREADS:-}" ] || CODEX_THREADS="$(git rev-parse --show-toplevel 2>/dev/null)/skills/mstack-handoff/scripts/codex_threads.py"
[ -f "${CODEX_THREADS:-}" ] || { echo "mstack-handoff: codex_threads.py not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "mstack-handoff: python3 not found (required for the Codex extractor)"; exit 1; }
```

### (a) Pick the thread

If `$ARGUMENTS` already names a thread (an id, a unique prefix, or a
rollout path), use it directly — `extract` errors with a candidate list if
a prefix is ambiguous. Otherwise list and ask:

```bash
python3 "$CODEX_THREADS" list --cwd "$(pwd)"
```

Show the results and have the user pick a thread (the short id is enough).
If none are found for this repo, say so and stop — never guess a thread
from a different project.

### (b) Extract a condensed transcript

```bash
EXTRACT_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-extract-XXXXXX.md")"
python3 "$CODEX_THREADS" extract "<thread-id-or-prefix>" --out "$EXTRACT_FILE"
```

Always extract to a scratch/temp path, never into the repo — the
checkpoint written in step (c) is the only artifact this mode adds to the
repo. The default `--max-chars` budget is tuned for a handoff-writing
read; raise it with `--max-chars N` only if the extract looks thin next to
what `list` reported (token count, turn count) for that thread.

### (c) Draft and verify — delegate this

The extract can be large. Delegate steps (c) and (d) to a sub-agent when
the host supports one, preferring a cheaper/faster model than the one
running this skill (same reasoning as `mstack-run` Step 3d: keep the
parent's context lean while the noisy work happens elsewhere). Claude
Code: one `Agent` call (e.g. a Haiku- or Sonnet-class model). Codex: spawn
one subagent the same way if the harness supports it. If no subagent
capability exists, do (c) and (d) directly instead of skipping them.

Give the sub-agent a self-contained prompt containing:

- The path to `$EXTRACT_FILE` (it reads this, not the live rollout — it
  never needs `$CODEX_THREADS` or DB/sqlite access).
- The exact checkpoint path to write:
  `.mstack/handoffs/{YYYY-MM-DD}-handoff-{NN}-{short-summary}.md`, with
  `{NN}` resolved the normal way (check today's existing handoff files
  first, per **Checkpoint file details** below).
- The **What to write** structure from this skill, verbatim, plus two
  additions specific to this mode:
  - The file's first line must be exactly:
    `<!-- CONTEXT ONLY: Do not start work. Wait for the user to run a command. -->`
  - Directly under the title, a line:
    `Source: Codex thread <id> (reconstructed from the rollout; Codex
    reasoning was encrypted and is not included).`
- Step (d) below, to run itself and fold into the draft before writing —
  not to write an unverified draft and verify after.
- An instruction to write the file directly and reply with only: the
  resolved short-summary, the final file path, a one-line cleanup-check
  summary, and any uncommitted/unpushed repo state found in (d). The full
  checkpoint body should never round-trip back through the parent's
  context.

### (d) Verify against disk — disk wins

Every checkable claim in "Current state" and "Files touched" must be
checked before the checkpoint is written:

- For each file the extract's heuristic file list names, and any other
  file path mentioned in the transcript's user/assistant text, confirm it
  still exists and, where feasible, that its content matches what the
  transcript claims. On a mismatch, disk wins — correct the claim, don't
  average the two.
- For every git repo the thread appears to have touched (its own `cwd`,
  plus any other repo paths seen in commands or file paths), run
  `git status` there and report uncommitted changes and unpushed commits
  in "Current state" / "Files touched" — the same information the normal
  flow's pre-handoff artifact check surfaces for a live session.
- Anything that can't be resolved this way (a claim about external
  state — a published post, a sent email, a third party's reply) goes in
  "Open questions for the user," never into "Current state" as fact. No
  invented facts: an honest "unconfirmed in the reconstructed transcript"
  is the correct, expected output here.

### (e) Deliver

The checkpoint from (c)/(d) is already written by this point. Probe for
spawn capability the same way the normal flow does:

```bash
bash "$HANDOFF_HELPER" cctrl-status
```

Then offer the normal delivery choice, narrowed to the two options that
make sense for a checkpoint reconstructed this way — this mode never
dumps the reconstructed content into chat:

- **Save handoff checkpoint** (default) — tell the user the path and the
  resume command, exactly as in **After writing** below.
- **Save + spawn fresh session** — only if `cctrl-status` reported
  `available=true`. Follow the **Spawn mode** steps below starting from
  "Spawn and validate in one deterministic step" (the checkpoint is
  already written, so its step 1 is already done).

**Resuming must go through the chat command, not a direct file read.**
Tell the user to resume by typing `resume from handoff <short-summary>`
(the spawned session's seed already sends exactly that — see **Spawn
mode**). If an agent instead opens the checkpoint file with a file-read
tool, the file is never deleted, because the auto-delete lives in
`handoff.sh resume`, not in the file itself. The checkpoint is single-use
only when it is resumed through the skill.

## Normal handoff flow

Output a handoff summary so a fresh session can pick up the work without inheriting the current session's baggage (failed attempts, dead-end assumptions, accumulated context noise).

This is meant to be used *before* `/clear` or before stepping away.

## When to invoke

- User explicitly asks: "handoff", "write a handoff", "I'm stepping away"
- User is about to `/clear` or close the session
- **Proactively**: the session is long and you've tried the same fix more than twice without success, suggest a handoff rather than another retry. Compacting won't help here; the dead-end reasoning is what needs to be dropped.

## Delivery mode

Before asking, probe for an optional spawn capability (silent when absent):

```bash
bash "$HANDOFF_HELPER" cctrl-status
```

If the first line is `available=false`, ignore this entirely — do not mention
cctrl, spawning, or session-closing anywhere in the flow. The user is none the
wiser. If it is `available=true`, capture the `session=` value (the current
tmux session id) and `target=` for later.

After gathering content (see "How to gather the content" below) but before
writing the handoff, ask the user how they want it delivered using
Ask the user directly; use AskUserQuestion when the host provides it:

- **Output in chat** — the handoff is printed inside a single fenced code
  block (` ```markdown ... ``` `) so the user can copy-paste the entire thing
  cleanly into a new session. No text inside the code block, no text before
  or after it except the resume instruction.
- **Save handoff checkpoint** — the handoff is written to a file under
  `.mstack/handoffs/` and the user resumes with "resume from handoff" in a
  new session.
- **Save + spawn fresh session** *(offer only when `cctrl-status` reported
  `available=true`)* — the handoff is written to a checkpoint, then a new
  detached cctrl session is launched and seeded to load that handoff and wait.
  The current session is left running; closing it is a separate, confirmed
  step (see **Spawn mode** below).

If the user has already explicitly said "save to file" or "write a checkpoint",
skip the question and go straight to checkpoint mode.

### Spawn mode

Only reachable when `cctrl-status` reported `available=true` and the user
picked **Save + spawn fresh session**.

1. Write the checkpoint exactly as in normal checkpoint mode (so the
   `{short-summary}` exists). Do not print the full handoff body in chat.
2. Spawn and validate in one deterministic step:

   ```bash
   bash "$HANDOFF_HELPER" spawn <short-summary>
   ```

   This launches a detached session seeded with `resume from handoff
   <short-summary>` and then polls until a new managed session appears.

   - On `spawn_ok=false`: tell the user the spawn did not come up, that **the
     current session is untouched**, and give them the manual resume command
     (`resume from handoff <short-summary>` in a new session). Stop here — do
     not offer to close anything.
   - On `spawn_ok=true`: report `new_session` and the `attach_command`. The new
     agent is waiting on the handoff; it will not start work on its own.
3. Only after a verified `spawn_ok=true`, ask whether to close the current
   session. **Show the current session id** (the `session=` value captured from
   `cctrl-status`) in the question so the user can confirm it is the right one
   to close, e.g.:

   > New session `TMUX--ms--mstack--3` is up and waiting on the handoff.
   > Close this session (`TMUX--ms--mstack--2`) now? It will keep running
   > otherwise.

   - If yes: `bash "$HANDOFF_HELPER" close-self` (uses cctrl's grace period so
     this turn finishes before the pane is killed).
   - If no: leave it running and remind the user they can close it themselves
     with `cctrl close` whenever they are ready.

   Never close the current session without this explicit confirmation, and
   never close it before `spawn_ok=true`.

### Checkpoint file details

Directory: `.mstack/handoffs/` (create if it doesn't exist).

Filename convention:
```
{YYYY-MM-DD}-handoff-{NN}-{short-summary}.md
```
Where `{NN}` is a zero-padded counter for handoffs on that day (01, 02, ...).
Check for existing handoff files with today's date to determine the next
number. Example: `2026-05-15-handoff-01-shopping-ai-hardware.md`.

After saving, tell the user (using the actual short-summary from the filename):

```
Handoff saved to .mstack/handoffs/<filename>

To resume in a new session, say: resume from handoff <short-summary>
```

For example: `resume from handoff shopping-ai-hardware`

Do NOT print the full handoff content in chat when saving to a file — just
confirm the path and the resume command.

## What to write

Use this exact structure. Every section is required, even if brief. Empty sections defeat the purpose.

```markdown
<!-- CONTEXT ONLY: Do not start work. Wait for the user to run a command. -->

# Handoff: <one-line task description>

**Date:** <YYYY-MM-DD>
**Branch:** <current git branch, or "n/a">

## Goal
<What the user is ultimately trying to accomplish. Not the immediate
sub-task, the actual objective. One or two sentences.>

## Current state
<Where things stand right now. What's working, what's not. Be concrete.>

## Files touched
<Bulleted list of file paths modified, created, or under active investigation.
Note uncommitted vs committed changes.>

## What's been tried and failed
<This is the highest-value section. For each failed attempt:
- What was tried
- Why it didn't work (the actual reason, not just "it broke")
- What this rules out

If you skip this, the next session will repeat the same dead ends.>

## What's been ruled out
<Hypotheses or approaches that have been investigated and dismissed,
with one-line reasoning. Keeps the next session from re-litigating
settled questions.>

## Next step
<The single most promising thing to try next. Format as a command for
the USER to type, not as an instruction the agent should execute.

If the next step involves running plans and the current harness supports a
native `/goal` command, output the exact goal command. Do not output a direct
`/mstack-run` command alongside it: the goal is the continuation driver.

  Run: /goal complete mstack plans 008, 009, 010, 011 via mstack-run orchestration

The `via mstack-run orchestration` clause is required. It keeps the resumed
goal on the MStack execution path: the parent is the orchestrator and each
plan's implementation is delegated to `mstack-worker`.

Use `/mstack-run 042` only when native goals are unavailable, or an explicit
project safety rule requires a watched manual iteration.

If the next step is something else, still phrase it as a user action:

  Run: /mstack-plan-doctor

Never write prose that reads like a task instruction (e.g., "implement
the billing feature" or "run the 3 unblocked plans"). The receiving
agent will interpret that as a directive and start working immediately
instead of waiting for the user to invoke /goal.>

## Open questions for the user
<Anything that needs a human decision before progress is possible.
Empty is fine if none.>
```

## Pre-handoff artifact check

Before generating the handoff output, scan the working tree for leftover
artifacts from the session's work. This catches temporary files that
should be cleaned up or acknowledged before handing off.

The scan itself is deterministic and lives in one place:
`mstack-run/scripts/wrapup-scan.sh` (read-only; it reports, it never
deletes). Do not re-improvise the pattern list or the porcelain parse here
— the script is the source of truth for both.

### Steps

1. Resolve and run the shared scan helper:

   ```bash
   for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
     [ -x "${_skill_base}/mstack-run/scripts/wrapup-scan.sh" ] && { SCAN_HELPER="${_skill_base}/mstack-run/scripts/wrapup-scan.sh"; break; }
   done
   [ -n "${SCAN_HELPER:-}" ] || SCAN_HELPER="$(git rev-parse --show-toplevel 2>/dev/null)/skills/mstack-run/scripts/wrapup-scan.sh"
   [ -x "$SCAN_HELPER" ] || { echo "mstack-handoff: wrapup-scan helper not found"; exit 1; }

   bash "$SCAN_HELPER"
   ```

2. Read its output. Per repo it emits a `repo=<path>` header, then
   `section=<name> count=<n>` lines (`uncommitted`, `artifacts`, `stashes`,
   `merged-branches`, `unpushed`) each followed by its entries on
   two-space-indented lines, then `findings=<N>`. Exit 29 means a target was
   not a git repository (report that, don't pretend the tree is clean); a
   nonzero exit never means "clean".

3. For the handoff, use the `artifacts` section (untracked files whose names
   look like session litter — the patterns are advisory heuristics, so
   classify each as litter vs deliberate) and the `stashes` count. The other
   sections are context; mention them only if relevant to the handoff.

4. Report findings in the handoff output (do NOT delete anything; the
   user decides):

   If artifacts found:
   ```
   Cleanup check:
     N untracked files may be artifacts:
       <filename> (<brief context if known>)
     M git stash entries
   ```

   If nothing found:
   ```
   Cleanup check: working tree is clean
   ```

5. Include the cleanup check output just before the "After writing"
   section in the handoff flow. It is informational; it does not block
   the handoff.

## How to gather the content

Before writing, briefly:
1. Run `git status` and `git diff --stat` to check for uncommitted changes.
2. **If uncommitted changes exist**, ask before proceeding:
   ```
   You have uncommitted changes. Commit them before generating the handoff?
   (A WIP commit preserves the state; the next session can amend or continue.)
   ```
   If yes, commit with `WIP: <summary of in-progress work>`. Never `git add .`,
   only stage the files related to the current task. Then re-run `git status`.
3. Skim the recent conversation for failed attempts (these are easy to forget). Include each one with its failure mode.
4. Run the pre-handoff artifact check (see above) and include results in the handoff.
5. If a plan or task list exists in this session, fold its open items into "next step" / "open questions".

Don't pad. A 30-line `handoff.md` with sharp failure analysis beats a 200-line one full of narration.

## After writing

Tell the user how to resume depending on the delivery mode:

- **Chat mode:** "You can `/clear` and paste the handoff into a fresh session, then run the command shown in 'Next step' to resume."
- **Checkpoint mode:** "You can `/clear` or start a new session and say `resume from handoff` to pick up where you left off."
- **Spawn mode:** handled inline by the **Spawn mode** steps above (report the
  new session and the attach command, then ask before closing the current
  one); no additional resume instructions are needed here.

## Handoff cleanup

Handoff checkpoints are single-use artifacts. Two cleanup mechanisms:

### Auto-delete on resume

When a session loads a handoff file (via "resume from handoff"), the file is
deleted after its contents have been read and presented. The handoff has served
its purpose.

### Auto-prune stale handoffs

At the start of any handoff invocation, prune handoff files older than 7 days:

```bash
bash "$HANDOFF_HELPER" prune
```

This catches handoffs that were never resumed.

## Resume from handoff

When the user says "resume from handoff" (routed here by
`AGENTS.md`/`CLAUDE.md`).
`$ARGUMENTS` will be "resume" or "resume <short-summary>".

This mode is implemented by `handoff.sh resume`.

1. Extract the short-summary from `$ARGUMENTS` if provided (everything after
   "resume "). If only "resume" with no name, fall back to the most recent file.
2. Load and delete the checkpoint through the helper:
   ```bash
   bash "$HANDOFF_HELPER" resume "<short-summary>"
   ```
   If no short-summary was provided:
   ```bash
   bash "$HANDOFF_HELPER" resume
   ```
3. If no file matches or the short-summary is ambiguous, report the helper's
   diagnostic. Suggest they run `/mstack-handoff list` or paste a handoff from
   a previous session instead.
4. Do NOT start working automatically. The handoff contains a "Next step"
   section with a command for the user to run. Tell the user:
   "Handoff loaded. Run the command in 'Next step' when you're ready."

## What NOT to do

- Don't write a chronological session log. This is a forward-looking handoff, not a postmortem.
- Don't include code snippets unless they're the actual broken state being handed off.
- Don't soften the failure section ("we explored several promising avenues"). Be blunt about what didn't work and why. That's the whole point.

## Optional continuation report

After a handoff file is successfully saved, report `continuation` for the actual current plan through the shared `paperclip_lifecycle.sh emit` wrapper, using `--repo "$REPO_ROOT" --plan "$PLAN_FILE" --outcome continuation --json "$REPO_ROOT/.mstack/paperclip-session.json"`. Resolve the mstack-run directory with the standard lookup. Structured metadata contains actual session/worktree and the saved handoff path in `note`. Skip when no specific plan is known; never invent a plan or completion. Output-only, list and resume modes do not emit a new handoff event. Show pending/conflict and continue; disabled mode stays a shell no-op.
