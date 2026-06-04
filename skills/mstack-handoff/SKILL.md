---
name: mstack-handoff
description: |
  Handoff summary for session transitions. Two modes: output in chat (paste
  into new session) or save a handoff checkpoint to .mstack/handoffs/ (resume
  with "resume from handoff" in a new session). Checkpoints are auto-deleted
  on resume and auto-pruned after 7 days.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - Write
---

# Handoff

User input (optional):

```
$ARGUMENTS
```

## Mode detection

If `$ARGUMENTS` contains "resume" (e.g., invoked via routing rule with args
"resume"), skip directly to the **Resume from handoff** section below. Do not
generate a new handoff.

Otherwise, proceed with the normal handoff flow.

## Normal handoff flow

Output a handoff summary so a fresh session can pick up the work without inheriting the current session's baggage (failed attempts, dead-end assumptions, accumulated context noise).

This is meant to be used *before* `/clear` or before stepping away.

## When to invoke

- User explicitly asks: "handoff", "write a handoff", "I'm stepping away", "wrap this up for now"
- User is about to `/clear` or close the session
- **Proactively**: the session is long and you've tried the same fix more than twice without success, suggest a handoff rather than another retry. Compacting won't help here; the dead-end reasoning is what needs to be dropped.

## Delivery mode

After gathering content (see "How to gather the content" below) but before
writing the handoff, ask the user how they want it delivered using
AskUserQuestion:

- **Output in chat** — the handoff is printed as a markdown message. The user
  copies it and pastes it into a new session.
- **Save handoff checkpoint** — the handoff is written to a file under
  `.mstack/handoffs/` and the user resumes with "resume from handoff" in a
  new session.

If the user has already explicitly said "save to file" or "write a checkpoint",
skip the question and go straight to checkpoint mode.

### Checkpoint file details

Directory: `.mstack/handoffs/` (create if it doesn't exist).

Filename convention:
```
{YYYY-MM-DD}-handoff-{NN}-{short-summary}.md
```
Where `{NN}` is a zero-padded counter for handoffs on that day (01, 02, ...).
Check for existing handoff files with today's date to determine the next
number. Example: `2026-05-15-handoff-01-shopping-ai-hardware.md`.

After saving, tell the user:

```
Handoff saved to .mstack/handoffs/<filename>

To resume in a new session, say: resume from handoff
```

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

If the next step involves running plans, output the exact /goal command:

  Run: /goal complete mstack plans 008, 009, 010, 011

If the next step is something else, still phrase it as a user action:

  Run: /mstack-plan-doctor
  Run: /mstack-run 042

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

### Steps

1. Check `git status --porcelain` for untracked files
2. Filter for likely artifacts matching these patterns:
   - `*.tmp`, `*.bak`, `*.orig` -- temporary/backup files
   - `test-*`, `debug-*` -- ad-hoc test and debug scripts
   - `*.log` -- log files
3. Check `git stash list` for stashed changes that may belong to the
   current work
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

## Handoff cleanup

Handoff checkpoints are single-use artifacts. Two cleanup mechanisms:

### Auto-delete on resume

When a session loads a handoff file (via "resume from handoff"), the file is
deleted after its contents have been read and presented. The handoff has served
its purpose.

### Auto-prune stale handoffs

At the start of any handoff invocation, prune handoff files older than 7 days:

```bash
find .mstack/handoffs/ -name "*-handoff-*" -mtime +7 -delete 2>/dev/null
```

This catches handoffs that were never resumed.

## Resume from handoff

When the user says "resume from handoff" (routed here by CLAUDE.md):

1. Find the most recent handoff file:
   ```bash
   ls -t .mstack/handoffs/*-handoff-*.md 2>/dev/null | head -1
   ```
2. If no file exists, tell the user: "No handoff checkpoint found in .mstack/handoffs/. You may need to paste a handoff from a previous session instead."
3. If a file exists, read its contents and present them to the user as context.
4. Delete the file (auto-cleanup on resume).
5. Do NOT start working automatically. The handoff contains a "Next step"
   section with a command for the user to run. Tell the user:
   "Handoff loaded. Run the command in 'Next step' when you're ready."

## What NOT to do

- Don't write a chronological session log. This is a forward-looking handoff, not a postmortem.
- Don't include code snippets unless they're the actual broken state being handed off.
- Don't soften the failure section ("we explored several promising avenues"). Be blunt about what didn't work and why. That's the whole point.
