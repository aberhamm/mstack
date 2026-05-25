---
name: mstack-handoff
description: Output a handoff summary in chat capturing goal, current state, files touched, what's been tried, what failed and why, and next steps — so a fresh Claude Code session can resume cleanly. Optionally write to a file if the user requests it.
allowed-tools:
  - Bash
  - Read
---

# Handoff

Output a handoff summary in chat so a fresh session can pick up the work without inheriting the current session's baggage (failed attempts, dead-end assumptions, accumulated context noise).

This is meant to be used *before* `/clear` or before stepping away. The user pastes the handoff into a new session to resume from a clean slate.

## When to invoke

- User explicitly asks: "handoff", "write a handoff", "I'm stepping away", "wrap this up for now"
- User is about to `/clear` or close the session
- **Proactively**: the session is long and you've tried the same fix more than twice without success — suggest a handoff rather than another retry. Compacting won't help here; the dead-end reasoning is what needs to be dropped.

## What to write

By default, output the handoff directly in chat as a markdown message — do NOT write a file unless the user explicitly asks for one.

If the user requests a file, write it to the current working directory with this naming convention:
```
{YYYY-MM-DD}-handoff-{NN}-{short-summary}.md
```
Where `{NN}` is a zero-padded counter for handoffs on that day (01, 02, ...). Check for existing handoff files with today's date to determine the next number. Example: `2026-05-15-handoff-01-shopping-ai-hardware.md`.

Use this exact structure — every section is required, even if brief. Empty sections defeat the purpose.

```markdown
# Handoff — <one-line task description>

**Date:** <YYYY-MM-DD>
**Branch:** <current git branch, or "n/a">

## Goal
<What the user is ultimately trying to accomplish. Not the immediate
sub-task — the actual objective. One or two sentences.>

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
<The single most promising thing to try next. One concrete action,
not a menu. If there are real alternatives, list them in priority order
with a one-line rationale each.>

## Open questions for the user
<Anything that needs a human decision before progress is possible.
Empty is fine if none.>
```

## How to gather the content

Before writing, briefly:
1. Skim the recent conversation for failed attempts — these are easy to forget. Include each one with its failure mode.
2. Run `git status` and `git diff --stat` to ground the "files touched" section in reality.
3. If a plan or task list exists in this session, fold its open items into "next step" / "open questions".

Don't pad. A 30-line `handoff.md` with sharp failure analysis beats a 200-line one full of narration.

## After writing

If `git status` shows uncommitted changes, ask:

```
You have uncommitted changes. Commit them before handing off?
(A WIP commit preserves the state — the next session can amend or continue.)
```

If yes, commit with `WIP: <summary of in-progress work>` — never `git add .`,
only stage the files related to the current task.

Then tell the user they can `/clear` and paste the handoff into a fresh session to resume.

## What NOT to do

- Don't write a chronological session log — this is a forward-looking handoff, not a postmortem.
- Don't include code snippets unless they're the actual broken state being handed off.
- Don't soften the failure section ("we explored several promising avenues"). Be blunt about what didn't work and why — that's the whole point.
- Don't write a file unless the user explicitly asks for one.
