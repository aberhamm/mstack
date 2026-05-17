---
name: mstack-learnings
description: |
  Self-healing knowledge base for mstack plan skills. Learns from plan
  executions, applies relevant knowledge to future plans, and prunes stale
  or conflicting information. Called by mstack-work-next-plan automatically,
  or invoked directly to review/manage learnings.
argument-hint: "[list | prune | search <query>]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
---

You manage a self-healing knowledge base that improves plan execution over
time. Learnings are project-specific patterns, pitfalls, and conventions
discovered during plan implementation.

User input (optional):

```
$ARGUMENTS
```

## Storage

- **Project learnings**: `$REPO_ROOT/.mstack/learnings.jsonl` — patterns specific
  to this codebase. Add `.mstack/` to `.gitignore` if missing.
- **Global learnings**: `~/.mstack/learnings.jsonl` — cross-project patterns
  (e.g., "Django projects always need migrations after model changes").

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

**Fields:**
- `key`: unique identifier, used for dedup and conflict resolution
- `insight`: the actual knowledge (actionable, concrete)
- `type`:
  - `pattern` — "this is how things are done here" (reuse in future plans)
  - `pitfall` — "don't do X because Y" (avoid in future plans)
  - `convention` — "this project uses X style for Y" (consistency)
  - `dependency` — "X requires Y to be set up first" (ordering)
- `evidence`: which plan discovered this
- `confidence`: 1-10 (higher = more certain, verified multiple times)
- `refs`: file paths or directories this learning relates to
- `created`: when first discovered
- `last_verified`: last time prune confirmed this is still valid

## Modes

### Default (no argument) — called by mstack-work-next-plan

When called with no argument, run the full cycle: **prune → apply → learn**.
This is the integration point for the autonomous worker.

### `list` — show all learnings

Print all learnings grouped by type, with confidence scores:

```
Project learnings (12 entries):

  PATTERN (5):
    [9] api-handlers-need-auth — All route handlers in src/api/ must wrap with authMiddleware
    [8] tests-use-factories — Tests use factory fixtures, never raw object literals
    ...

  PITFALL (3):
    [9] no-direct-db-in-handlers — Never import db directly in handlers; use the service layer
    ...

  CONVENTION (3):
    ...

  DEPENDENCY (1):
    ...

Global learnings (4 entries):
  ...
```

### `prune` — remove stale/conflicting learnings

Run the full prune cycle (see Step 1 below) and report what was removed.

### `search <query>` — find relevant learnings

Search both project and global learnings for entries matching the query.
Match against `key`, `insight`, and `refs`. Print matching entries.

---

## Step 1 — Prune (self-healing)

Run at the start of every cycle. For each learning:

1. **Check refs exist.** For each path in `refs`:
   - If it's a file: verify it exists on disk.
   - If it's a directory: verify it exists.
   - If >50% of refs are gone, the learning is **stale** — delete it.
   - If some refs are gone but others remain, update `refs` to only the
     valid ones and reduce `confidence` by 2.

2. **Check for conflicts.** If two learnings have the same `key` or directly
   contradictory `insight` values:
   - Keep the one with higher confidence.
   - If equal confidence, keep the newer one (`created` date).
   - Delete the loser.

3. **Decay low-confidence entries.** If `confidence` <= 3 AND `last_verified`
   is older than 30 days, delete it. Unverified weak signals aren't worth
   carrying.

4. **Report:** Print how many entries were pruned and why (one line each).
   If nothing pruned: "Learnings clean (N entries)."

## Step 2 — Apply (inform current execution)

Read all project + global learnings. For the current plan being executed
(passed via context from `mstack-work-next-plan`):

1. Match learnings where `refs` overlap with the plan's
   `**Files expected to change:**` list.
2. Match learnings where `key` or `insight` keywords relate to the plan's
   title or requirements.
3. Surface matched learnings as implementation guidance:

```
Relevant learnings for plan 042:
  [9] api-handlers-need-auth — All route handlers in src/api/ must wrap with authMiddleware
  [7] error-responses-use-problem-json — Error responses follow RFC 7807 Problem Details format
```

The implementing agent should treat these as constraints/guidance during
Step 4 (implement).

## Step 3 — Learn (extract from completed plan)

After a plan succeeds, analyze what was implemented and extract 0-2 new
learnings. Only extract if the pattern is:

- **Non-obvious** — can't be inferred from reading CLAUDE.md or file names
- **Reusable** — would help a future plan in the same area
- **Concrete** — names specific files, patterns, or constraints

**What to extract:**
- Architectural patterns discovered ("services always go through the queue")
- Pitfalls encountered during implementation ("the ORM doesn't support X")
- Convention violations that were caught by the gate ("imports must use .js extension")
- Dependency ordering ("must run migrations before seeding")

**What NOT to extract:**
- Anything already in CLAUDE.md
- One-time fixes (typos, missing semicolons)
- Obvious language features
- Anything specific to a single plan that won't recur

For each new learning:
1. Check if a learning with the same `key` already exists.
   - If yes and new evidence increases confidence: bump confidence, update
     `last_verified`, add new refs.
   - If yes and contradicts: replace old with new (newer evidence wins).
   - If no: append new entry.
2. Write to the project learnings file (or global if it's truly cross-project).

---

## Integration with mstack-work-next-plan

The worker calls into this skill at three points:

1. **Before Step 4 (implement):** Run `prune` then `apply` — surfaces relevant
   learnings as implementation guidance.
2. **After Step 7a (success commit):** Run `learn` — extracts patterns from
   what was just implemented.
3. **After Step 7b (failure):** Run `learn` with failure context — extracts
   pitfalls from what went wrong.

The worker does NOT need to invoke this as a separate `/skill` call. Instead,
it runs the logic inline:

```bash
# Ensure .mstack directory exists
mkdir -p "$REPO_ROOT/.mstack"
# Ensure .mstack is gitignored
grep -q "^\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".mstack/" >> "$REPO_ROOT/.gitignore"
```

Then reads/writes `$REPO_ROOT/.mstack/learnings.jsonl` directly following
the prune/apply/learn logic described above.
