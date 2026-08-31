---
name: mstack-stash
description: |
  Save an unresolved conversation thread for later. Not a plan, not a task,
  not a commitment, just a thinking artifact you can resume cold. Lists,
  saves, and resumes stashed threads from .mstack/stashed/.
  Not this skill if: you want to carry this session's working state into the
  next session (use /mstack-handoff, the continuation tool), or you want to
  harvest the session's knowledge into the repo before closing (use
  /mstack-wrap-up, the terminal one). Stash is neither: it parks a thought.
triggers:
  - stash this
  - save this for later
  - come back to this later
  - park this thought
  - I'm not ready to plan this yet
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
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

You are running `/mstack-stash`. Parse the user's input to determine the mode:

- No arguments → **List mode**
- A quoted string (e.g., `"auth token strategy"`) → **Save mode**
- `resume <number or keyword>` → **Resume mode**
- `delete <number or keyword>` → **Delete mode**

## Setup

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
STASH_DIR="$REPO_ROOT/.mstack/stashed"
mkdir -p "$STASH_DIR"
```

Ensure `.mstack/stashed/` is gitignored:

```bash
if ! grep -q "\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null; then
  echo ".mstack/" >> "$REPO_ROOT/.gitignore"
fi
```

## List mode

Print all stashed threads with index, date, and title:

```bash
ls -1 "$STASH_DIR"/*.md 2>/dev/null | sort
```

For each file, extract the first `# ` heading and the `Stashed:` date line.
Format as:

```
Stashed threads (N):

  1. [2026-05-24] Auth token refresh strategy
  2. [2026-05-21] Notification system architecture
  3. [2026-05-19] Migration to edge functions
```

If no files exist, print: "No stashed threads. Use `/mstack-stash \"title\"` to save one."

## Save mode

The user wants to capture the current conversation thread.

1. Generate a slug from the title: lowercase, hyphens, no special chars, max 50 chars.
2. Find the next available number prefix. Derive it from the highest existing
   numeric prefix, not from the file count — files are never renumbered after a
   delete, so a count-based next number collides with an existing file:
   ```bash
   MAX_NUM=$(ls "$STASH_DIR" 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1)
   NEXT_NUM=$(( ${MAX_NUM:-0} + 1 ))
   ```
3. Create the file at `$STASH_DIR/${NEXT_NUM}-${SLUG}.md`

Write this structure:

```markdown
# <title>

Stashed: <YYYY-MM-DD>

## Context

<Summarize what the conversation was about: the problem space,
what prompted the thinking, any relevant background. Write 2-5
sentences from the conversation context.>

## Decisions So Far

<Bullet list of anything decided or agreed upon during the
conversation. If nothing was decided yet, write "None yet.">

## Open Questions

<Bullet list of what's still unresolved, the things that need
more thought before this becomes actionable. These are the reason
this is stashed, not planned.>

## Useful Pointers

<Any file paths, links, commands, or references that would help
resume this thread. Optional; omit the section if nothing applies.>
```

Fill in the sections by reading back through the conversation context.
Be concise; this is a resumption aid, not documentation.

After writing, print:
```
Stashed: "<title>" → .mstack/stashed/<filename>
```

## Resume mode

The user wants to pick up a stashed thread.

1. Match the argument:
   - If a number: find the file at that index (sorted order)
   - If a keyword: grep filenames and content for the best match

2. Read the file and print its full contents.

3. After printing, say:
   ```
   Thread loaded. Continue the conversation, or `/mstack-stash delete N`
   when you're done with it.
   ```

The stashed content becomes context for the rest of the conversation.

## Delete mode

1. Match the argument (same as resume)
2. Delete the file
3. Print: `Deleted: "<title>"`

Do not renumber remaining files. Numbers are convenience handles for
the current listing, not stable IDs.

## Rules

- No frontmatter schema. No YAML. Just markdown with headings.
- No validation, scoring, or doctor integration.
- No automatic promotion to plans.
- No priority, status, or workflow fields.
- Keep it intentionally simple. This is a thinking scratchpad.
