---
name: mstack-learned-patterns
description: |
  Self-healing knowledge base for mstack plan skills. Learns from plan
  executions, applies relevant knowledge to future plans, and prunes stale
  or conflicting information. Called by mstack-run automatically,
  or invoked directly to review/manage learnings.
argument-hint: "[list | prune | search <query>]"
allowed-tools:
  - Bash
  - Read
---

You manage a self-healing knowledge base that improves plan execution over
time. Learnings are project-specific patterns, pitfalls, and conventions
discovered during plan implementation.

User input (optional):

```
$ARGUMENTS
```

## Scripts

All data operations live in `learnings.sh`. Resolve the scripts directory:

```bash
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
[ -d "$SCRIPTS_DIR" ] || SCRIPTS_DIR="${HOME}/.claude/skills/mstack-run/scripts"
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/learnings.sh" list` | Print all learnings grouped by type |
| `bash "$SCRIPTS_DIR/learnings.sh" search <query>` | Search by keyword across key, insight, refs |
| `bash "$SCRIPTS_DIR/learnings.sh" prune` | Remove stale/conflicting entries, apply decay |
| `bash "$SCRIPTS_DIR/learnings.sh" append '<json>'` | Add or merge a learning entry |
| `bash "$SCRIPTS_DIR/learnings.sh" get <key>` | Get a specific entry by key |
| `bash "$SCRIPTS_DIR/learnings.sh" bump <key>` | Increase confidence and update last_verified |

The `prune` command handles all self-healing logic:
- Removes entries where >50% of `refs` paths no longer exist
- Deduplicates by `key` (keeps higher confidence)
- Deletes entries with confidence <= 3 unverified for 30+ days
- Applies graduated confidence decay: -1 per cycle for entries unverified 14+ days

The `append` command handles dedup/merge automatically: if a learning with
the same `key` exists, it bumps confidence and updates `last_verified`
instead of creating a duplicate.

## Storage

- **Project learnings**: `$REPO_ROOT/.mstack/learnings.jsonl`
- **Global learnings**: `~/.mstack/learnings.jsonl`

Each line is a JSON object:

```json
{
  "key": "short-kebab-slug",
  "insight": "One sentence describing the pattern or pitfall",
  "type": "pattern | pitfall | convention | dependency",
  "evidence": "plan-034",
  "confidence": 8,
  "refs": ["src/api/middleware.ts", "src/api/handlers/"],
  "created": "2026-05-16",
  "last_verified": "2026-05-16"
}
```

## Modes

### `list` — show all learnings

Run `bash "$SCRIPTS_DIR/learnings.sh" list` and present the output. The
script groups entries by type with confidence scores.

### `prune` — remove stale/conflicting learnings

Run `bash "$SCRIPTS_DIR/learnings.sh" prune` and report the result.

### `search <query>` — find relevant learnings

Run `bash "$SCRIPTS_DIR/learnings.sh" search <query>` and present matches.

### Default (no argument) — full cycle for mstack-run

When called with no argument (integration point for the autonomous worker),
run the full cycle: **prune → apply → learn**.

---

## Integration with mstack-run

The worker calls into this skill's logic at three points:

### Before Step 4 (implement): prune and apply

1. **Prune:** Run `bash "$SCRIPTS_DIR/learnings.sh" prune`

2. **Apply:** Read the plan's `**Files expected to change:**` list and its
   title/requirements. Then search for matching learnings:

   ```bash
   bash "$SCRIPTS_DIR/learnings.sh" search "<keyword from plan>"
   ```

   Run multiple searches if needed (by file path, by topic keyword). Surface
   matched learnings as implementation guidance:

   ```
   Relevant learnings for plan ${PLAN_ID}:
     [9] api-handlers-need-auth — All route handlers in src/api/ must wrap with authMiddleware
     [7] error-responses-use-problem-json — Error responses follow RFC 7807 format
   ```

   Treat these as constraints during implementation. If a learning contradicts
   the plan's explicit instructions, the plan wins (it was written by the human).

### After Step 7a (success) or 7b (failure): learn

Analyze what was implemented (or what failed) and extract 0-2 new learnings.
Only extract if the pattern is:

- **Non-obvious** — can't be inferred from reading CLAUDE.md or file names
- **Reusable** — would help a future plan in the same area
- **Concrete** — names specific files, patterns, or constraints

**On success**, look for:
- Architectural patterns ("services always go through the queue")
- Conventions the gate enforced ("imports must use .js extension")
- Dependencies discovered ("module X requires Y to be initialized first")

**On failure**, look for:
- Pitfalls ("the ORM doesn't support X, don't try it")
- Environmental constraints ("this test suite needs the DB running")
- Architectural blockers ("can't do X without first refactoring Y")

For each new learning, construct the JSON and write it:

```bash
bash "$SCRIPTS_DIR/learnings.sh" append '{"key":"<slug>","insight":"<one sentence>","type":"<type>","evidence":"plan-${PLAN_ID}","confidence":7,"refs":["<paths>"],"created":"<YYYY-MM-DD>","last_verified":"<YYYY-MM-DD>"}'
```

The script handles dedup/merge automatically. If nothing worth extracting,
skip silently.

**What NOT to extract:**
- Anything already in CLAUDE.md
- One-time fixes (typos, missing semicolons)
- Obvious language features
- Anything specific to a single plan that won't recur
