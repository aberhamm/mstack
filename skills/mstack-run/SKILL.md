---
name: mstack-run
description: |
  Pick the next unblocked plan from `docs/plans/` (or `plans/`), implement
  it directly on the default branch, run the project's verification gate
  (typecheck/lint/test), and commit. Designed for a solo-dev workflow that
  lives on `main`: no feature branches, no PRs, no automatic push. The
  user reviews the changelog and pushes when ready.

  Supports scoped execution by plan IDs: pass specific IDs to execute only
  those plans (e.g., `$ARGUMENTS` = `008, 009, 010` or `plans 008-011`).
  When no IDs are provided, falls back to picking the next unblocked plan
  from the entire backlog (backward compatible).

  Recommended driver: `/goal complete mstack plans 008, 009, 010, 011`
  which keeps working autonomously until the scoped plans are done or
  failed. Also works as a single manual invocation for one plan at a time.
triggers:
  - run the next plan
  - execute the backlog
  - work the plans
  - start the loop
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  # Add your notification MCP tool here if desired, e.g.:
  # - mcp__MCP_DOCKER__telegram-claude__send_message
---

You are running ONE iteration of an autonomous backlog worker. Do exactly
one plan, commit it, and exit. Do not chain into a second plan; `/goal`
handles continuation by evaluating whether the backlog is clear.

## Progress output

> **Read** `"$SKILL_DIR/references/progress-format.md"` before proceeding.

## Hard rules (never violate)

- **Never push to remote.** The user pushes manually after reviewing.
- **Never edit `db/migrations/**`** unless the picked plan's frontmatter
  has `allows-migrations: true`. Migrations run sequentially by hand.
- **Never bypass the verification gate.** If checks fail after
  investigation (3-strike rule), abandon the iteration and rollback
  (Step 7). Never commit broken code to `main`.
- **Never `--no-verify`, `--no-gpg-sign`, or any commit/push escape hatch.**
- **Never amend or rebase** prior commits. Each iteration is a single
  forward commit.
- **Never delete a plan file.** Set `status: failed` instead.

## Step 1: Startup

Run bail checks and load configuration. **Do not schedule another
iteration on bail**; the loop ends here.

### Auto-init

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-run" ] && { SKILL_DIR="${_skill_base}/mstack-run"; break; }
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

### Bail checks

```bash
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "BAIL: not a git repo"; exit 1; }

# Detect stale worktrees: .git is a file (not a dir) in worktrees
REPO_ROOT=$(git rev-parse --show-toplevel)
if [ -f "$REPO_ROOT/.git" ]; then
  WORKTREE_BRANCH=$(git branch --show-current)
  echo "BAIL: in a worktree ($WORKTREE_BRANCH) left over from a previous session."
  echo "Return to the main repo checkout, or remove the stale worktree with git worktree remove after confirming it is no longer needed."
  exit 1
fi

# Clean up stale worktrees from previous sessions before proceeding
STALE_WORKTREES=$(git worktree list --porcelain | grep "^worktree " | grep -v "$(git rev-parse --show-toplevel)$" | sed 's/^worktree //')
if [ -n "$STALE_WORKTREES" ]; then
  echo "$STALE_WORKTREES" | while read -r wt; do
    git worktree unlock "$wt" 2>/dev/null || true
    git worktree remove "$wt" --force 2>/dev/null || true
  done
  git worktree prune 2>/dev/null || true
  echo "Cleaned stale worktree(s) from previous session."
fi

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
[ "$(git branch --show-current)" = "$DEFAULT_BRANCH" ] || { echo "BAIL: not on $DEFAULT_BRANCH"; exit 1; }

[ -d docs/plans ] || [ -d plans ] || { echo "no plans dir, nothing to do"; exit 0; }
```

A dirty working tree is **allowed**; this skill coexists with parallel
user edits. The success/rollback paths in Step 7 use surgical add /
revert by explicit file list, never `git add .` or `git reset --hard`.

If anything fails, tell the user what went wrong in one sentence and stop.

### Load config

Read configuration using the config script:

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-run" ] && { SKILL_DIR="${_skill_base}/mstack-run"; break; }
done
bash "$SKILL_DIR/scripts/config.sh" show
```

Note the `health.commands`, `health.weights`, `review.provider`,
`ignored_paths`, and `commit` settings. Use
`bash "$SKILL_DIR/scripts/config.sh" get <dotpath>` for individual values
(e.g., `get health.weights.test`). The script falls back to built-in
defaults when no config exists.

### Crash recovery from checkpoint

Read the latest checkpoint using the checkpoint script:

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" read
```

Exit code 2 means no checkpoint exists. If a checkpoint exists:
- Carry forward `user_context` entries into your working memory. Treat them
  as constraints during implementation.
- Check if `plan_status` is `"in-progress"`, which means the previous session
  crashed mid-plan. Log: "Previous session crashed during plan ${plan_id}.
  Plan remains in-progress; pick-next will skip to the next plan."
- Read `counters` for continuity (plans completed so far, health trend).

### Prune stale checkpoints

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" prune
```

## Step 1b: Parse plan IDs and goal name from arguments (scoped execution)

Parse `$ARGUMENTS` for plan IDs and an optional goal name to enable scoped
execution. When plan IDs are provided, only those plans are considered for
execution. When a goal name is provided, matching plans are discovered
automatically. When neither is provided, fall back to the full backlog
(backward compatible).

Process `$ARGUMENTS` in this strict 5-step order:

```
Step 1 — Range expansion:
  Expand range formats before any other parsing.
  "008-011" → "008,009,010,011"
  "plans 008-011" → "plans 008,009,010,011"
  Ranges contain dashes, so expand first to avoid confusing them with slugs.

Step 2 — Numeric extraction:
  Extract all numeric tokens from the expanded arguments → SCOPE_IDS.
  Supported formats after expansion:
    - Space-separated: "008 009 010 011"
    - Comma-separated: "008,009,010,011"
    - Mixed: "008, 009, 010, 011"
    - Embedded in natural language: "complete mstack plans 008, 009"

Step 3 — Stop-word removal:
  Remove these stop words from the remaining (non-numeric) tokens:
    complete, mstack, plans, plan, are, done, failed, or, the,
    all, pending, run, execute, finish, goal
  Note: /goal itself is not in $ARGUMENTS (the /goal evaluator strips it).

Step 4 — Goal detection:
  After removing stop words and numeric tokens, check remaining tokens:
    - Zero tokens remain → no goal, proceed with SCOPE_IDS only.
    - Exactly one non-stop-word non-numeric token remains → GOAL_NAME.
      Example: "complete webhook-retry mstack plans" → GOAL_NAME="webhook-retry"
    - Multiple tokens remain → ambiguous, see Step 5.

Step 5 — Ambiguity check:
  If multiple candidate goal tokens remain after stop-word removal, print:
    [mstack] ERROR: ambiguous goal — multiple candidate tokens: <token1>, <token2>
    Provide a single goal slug or use numeric plan IDs.
  Then exit without picking a plan.
```

### Goal discovery (goal-scoped without explicit IDs)

When `GOAL_NAME` is set but `SCOPE_IDS` is empty, scan plan files for
matching `goal:` frontmatter to automatically build the scope:

```bash
for f in "$PLANS_DIR"/*.md; do
  plan_goal="$(fm_get "$f" goal)"
  if [ "$plan_goal" = "$GOAL_NAME" ]; then
    plan_id="$(fm_get "$f" id)"
    SCOPE_IDS="$SCOPE_IDS,$plan_id"
  fi
done
```

Also scan `"$PLANS_DIR"/archive/*.md` for already-completed plans in the
same goal (they count as done for dependency resolution).

If zero plans match the goal name, print:

```
[mstack] ERROR: no plans found with goal: <GOAL_NAME>
```

Then exit without picking a plan.

When both `GOAL_NAME` and explicit numeric IDs are provided, use the
explicit IDs as `SCOPE_IDS` — the goal is passed to the picker alongside
the numeric scope (AND composition).

### Scope validation

When SCOPE_IDS is set, validate that scoped plans can actually run. For
each plan in the scope, check its `blocked-by` list:

- If a dependency is in the scope or already `status: done`, it's fine.
  Archived plans (in `$PLANS_DIR/archive/`) count as done — the picker
  and status scripts scan both directories.
- If a dependency is outside the scope and NOT `status: done`, this is a
  scope error. Print:

  ```
  [mstack] ERROR: Plan 009 is blocked by plan 005, which is not in the
  execution scope and is not done. Either add 005 to the scope or
  complete it first.
  ```

  Then exit without picking a plan. `/goal` will see the error and stop.

This validation runs once at startup, before the first pick-next call.
It prevents the confusing situation where a scoped run picks up plan 008,
completes it, then gets stuck on 009 because of an unmet external dependency.

### Execution manifest

After scope validation passes, create (or validate an existing) execution
manifest to track scoped goal state across iterations:

```bash
if [ -n "$SCOPE_IDS" ]; then
  MANIFEST_STATUS=$(bash "$SKILL_DIR/scripts/manifest.sh" validate 2>&1) || true
  GOAL_FLAG=""
  [ -n "$GOAL_NAME" ] && GOAL_FLAG="--goal $GOAL_NAME"
  if [ "$MANIFEST_STATUS" = "NO_MANIFEST" ]; then
    bash "$SKILL_DIR/scripts/manifest.sh" create "$SCOPE_IDS" $GOAL_FLAG
  elif [ "$MANIFEST_STATUS" = "STALE" ]; then
    # Stale manifest from a crashed session — overwrite
    bash "$SKILL_DIR/scripts/manifest.sh" create "$SCOPE_IDS" $GOAL_FLAG
  fi
  # VALID manifest from a prior iteration — leave it, update will handle it
fi
```

## Step 2: Pick the next plan

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-run" ] && { SKILL_DIR="${_skill_base}/mstack-run"; break; }
done

# Use temp file pattern to preserve exit code under pipefail.
# Do NOT use NEXT=$(bash ...) which discards the exit code.
PICKER_TMPFILE=$(mktemp)
GOAL_ARG=""
[ -n "${GOAL_NAME:-}" ] && GOAL_ARG="--goal $GOAL_NAME"
if [ -n "$SCOPE_IDS" ]; then
  bash "$SKILL_DIR/scripts/pick-next.sh" "$SCOPE_IDS" $GOAL_ARG > "$PICKER_TMPFILE" 2>/tmp/picker_stderr; PICKER_EXIT=$?
else
  bash "$SKILL_DIR/scripts/pick-next.sh" $GOAL_ARG > "$PICKER_TMPFILE" 2>/tmp/picker_stderr; PICKER_EXIT=$?
fi
NEXT=$(cat "$PICKER_TMPFILE")
PICKER_STDERR=$(cat /tmp/picker_stderr 2>/dev/null || true)
rm -f "$PICKER_TMPFILE" /tmp/picker_stderr
```

The picker returns distinct exit codes (defined in `lib.sh`):

| Exit | Meaning | Action |
|------|---------|--------|
| 0 | Plan found | Proceed with `$NEXT` as the plan path |
| 10 | All done | Run simplify pass + completion notification (Step 8), print "Backlog clear." and exit |
| 11 | Scoped ID not found | Print stderr diagnostic, exit iteration |
| 12 | All blocked | Print stderr diagnostic (blocked deps), exit iteration |
| 13 | Dependency cycle | Print stderr diagnostic (cycle path), exit iteration |
| 14 | Duplicate IDs | Print stderr diagnostic (dup files), exit iteration |

Handle each exit code:

```
case $PICKER_EXIT in
  0)  # Plan found — proceed with NEXT
      ;;
  10) # All plans (or all scoped plans) are done
      # Run simplify pass and completion notification (Step 8),
      # print "Backlog clear." and exit.
      ;;
  11) # Scoped ID not found — fatal for this iteration
      echo "[mstack] ERROR: $PICKER_STDERR"
      # Exit; /goal will see the error and stop.
      ;;
  12) # All remaining scoped plans are blocked by out-of-scope deps
      echo "[mstack] ERROR: $PICKER_STDERR"
      # Exit; /goal will see the error and stop.
      ;;
  13) # Dependency cycle detected
      echo "[mstack] ERROR: $PICKER_STDERR"
      # Exit; /goal will see the error and stop.
      ;;
  14) # Duplicate plan IDs found
      echo "[mstack] ERROR: $PICKER_STDERR"
      # Exit; /goal will see the error and stop.
      ;;
  *)  # Unexpected exit code — treat as general error
      echo "[mstack] ERROR: picker failed with exit code $PICKER_EXIT"
      # Exit; /goal will see the error and stop.
      ;;
esac
```

The picker selects the lowest-priority pending plan whose dependencies are
met (lowest `priority:` first, then lowest `id:` as tiebreaker; plans
without `priority:` default to their `id:`). When SCOPE_IDS is provided,
only plans with matching IDs are considered (the SCOPE_FILTER in
pick-next.sh filters candidates before dependency sorting).

### Progress: goal label

When `GOAL_NAME` is set, print the goal slug before the backlog summary:

```
[mstack] Goal: <slug>
```

For example: `[mstack] Goal: webhook-retry`

### Progress: backlog summary

Before acting on the pick result, count all plans by status and print:

```
[mstack] Backlog: N pending, M blocked, K done, J failed
```

Read all plan files, tally by `status:` field (pending, blocked, done,
failed, in-progress). Print this line once per mstack-run invocation,
before the first plan starts or before reporting "Backlog clear."

If `PICKER_EXIT` is 10 (all done): run the simplify pass and completion
notification (Step 8), print "Backlog clear." and exit. The `/goal`
evaluator will see this and stop. If `PICKER_EXIT` is 11-14: print the
error diagnostic from stderr and exit the iteration immediately.

### Progress: plan header

When a plan is selected, compute N (how many plans are done so far + 1,
i.e., this plan's sequence number) and M (total plans in scope).

**When SCOPE_IDS is set (scoped execution):** M = number of scoped plan IDs
(i.e., `len(SCOPE_IDS)`), and N counts only done plans within the scope + 1.
This gives the user accurate progress against their scoped set, not the
full backlog.

**When SCOPE_IDS is empty (full backlog):** M = total plans (pending +
in-progress + done + failed, excluding blocked), N = done + 1.

Print:

```
[mstack] Plan N/M: <title> (plan <id>)
```

For example: `[mstack] Plan 2/4: Stripe webhook integration (plan 009)`
(where 4 is the number of scoped plans, not the total backlog)

Immediately claim the plan to prevent parallel sessions from picking it:

1. Update `status: pending` → `status: in-progress` in the plan's frontmatter.
2. Commit the claim:
   ```bash
   git add "$NEXT"
   git commit -m "chore(plan ${PLAN_ID}): claim, in progress"
   ```

This must happen before any other work. If the plan later fails the
readiness gate or implementation, the rollback/failure steps will handle
resetting the status.

## Step 3: Snapshot pre-existing edits and read context

```bash
RECOVERY=$(git rev-parse HEAD)
echo "Recovery point: $RECOVERY"

# Files the user already had modified or untracked before this iteration.
# We won't touch them in our success commit OR our failure rollback;
# they belong to the user's in-flight work.
PRE_DIRTY=$(git status --porcelain | awk '{print $2}' | sort -u)
echo "Pre-existing dirty files (off-limits to skill rollback):"
echo "$PRE_DIRTY"
```

Keep `$PRE_DIRTY` in mind throughout. If you need to edit a file that's
in this list, that's a real conflict. Flag it in the iteration's commit
message and let the user reconcile.

Read project guidance in this order: `AGENTS.md` first, then `CLAUDE.md`
(root + any nearer to the plan's scope). Note:
- Test/typecheck/lint commands (default: `pnpm test`, `pnpm -r typecheck`,
  `pnpm -r lint`).
- Any "Phase 0" / migration / RLS rules that affect the plan.

Read `$NEXT` end-to-end. Note its `id`, `title`, `blocked-by`,
`allows-migrations`, and the Implementation section.

## Step 3b: Plan readiness gate

Before implementing, verify the plan is fully specified. Check:

1. **Requirements section** has concrete acceptance criteria (`- [ ]` items).
   Placeholder text from the template does NOT count.
2. **Design section** has a `**Files expected to change:**` list with real
   file paths (not `path/to/file.ts`). Has an `**Out of scope:**` statement.
3. **Tasks section** has 2+ numbered steps with real instructions (not `...`).

If ANY of these are still template placeholders or missing:

1. Set the plan's `status: in-progress` → `status: blocked` and add
   `needs-review: eng` (or whatever review type fits based on title heuristics).
2. Commit only the plan file:
   ```bash
   git add "$NEXT"
   git commit -m "chore(plan ${PLAN_ID}): blocked, incomplete spec"
   ```
3. Print:
   ```
   plan ${PLAN_ID}: blocked (incomplete spec). Run /mstack-plan-doctor ${PLAN_ID} to fix.
   ```
4. Continue to Step 8 (schedule next iteration); skip to the next plan in
   the backlog rather than stopping the loop entirely.

Do NOT attempt to implement a plan with placeholder content. The human
must fill in the spec first.

## Step 3c: Learnings: prune and apply

**Prune:** Run the learnings pruner to remove stale/conflicting entries:

```bash
bash "$SKILL_DIR/scripts/learnings.sh" prune
```

**Apply:** Search for learnings relevant to this plan's files and topic.
Pass all search terms in a single call (the script deduplicates by key):

```bash
bash "$SKILL_DIR/scripts/learnings.sh" search "<keyword from plan title>" "<file path from plan>"
```

Add more arguments as needed (by file path, by topic keyword). Surface
matched learnings as implementation guidance:

```
Relevant learnings for plan ${PLAN_ID}:
  [9] api-handlers-need-auth: All route handlers in src/api/ must wrap with authMiddleware
  [7] error-responses-use-problem-json: Error responses follow RFC 7807 format
```

Treat these as constraints during implementation. If a learning contradicts
the plan's explicit instructions, the plan wins (it was written by the human).

### Stash check

Search `.mstack/stashed/` for threads related to this plan's title or files:

```bash
STASH_DIR="$REPO_ROOT/.mstack/stashed"
if [ -d "$STASH_DIR" ] && [ "$(ls -A "$STASH_DIR" 2>/dev/null)" ]; then
  grep -rl "<keyword from plan title>" "$STASH_DIR"/ 2>/dev/null || true
fi
```

If a stashed thread matches, print:

```
Related stash: "<title>", review with /mstack-stash resume N
```

This is informational only; do not block on it or require user action.
The plan proceeds regardless. The user can review the stash later.

## Step 3d: Delegate to implementation agent

Steps 4-6 are noisy (many file reads/edits, health runs, review agents).
Run them inside a **single implementation agent/subagent** so the parent
context stays lean across multi-plan loops. The parent sees only the
structured result.

Construct the Agent prompt from everything gathered in Steps 1-3c. The
prompt must be self-contained; the subagent has no prior context.

Claude Code: use one `Agent` call with description
`implement plan ${PLAN_ID}`.

Codex: spawn one `mstack-worker` subagent if the `.codex/agents/mstack-worker.toml`
agent is available; otherwise explicitly spawn one worker subagent with the
same prompt. Wait for the subagent result before continuing.

### Prompt template

> **Read** `"$SKILL_DIR/references/subagent-prompt.md"` before proceeding.
> Contains the full prompt template. Include its contents verbatim in the
> Agent call, substituting the variables gathered in Steps 1-3c.

### Parse the result

Extract the `---MSTACK-RESULT---` block from the agent's output.

- **`pass`** → proceed to Step 7a. Use MODIFIED + CREATED for the commit
  and SUMMARY for the implementation notes.
- **`fail`** → the agent already reverted and printed the `[mstack] └─ FAILED`
  line. Proceed to Step 7b (update plan status and commit only the plan file).
- **`blocked`** → the agent already updated the plan. Commit the plan
  file and continue to Step 8 (next plan, don't stop the loop).

**Skipped plans (blocked by failed dependencies):** If pick-next finds a
plan whose `blocked-by` includes a plan with `status: failed`, that plan
cannot run. Print:

```
[mstack] └─ SKIPPED: blocked by failed plan <id>
```

Update the skipped plan's status to `status: blocked` and add
`blocked-reason: dependency failed (plan <id>)`. Commit only the plan
file and continue to Step 8.

If the implementation agent errors or returns no result block, treat as a failure:
revert any uncommitted changes not in PRE_DIRTY, set the plan to
`status: failed` with `failed-reason: agent-error`, and continue.

---

Steps 4-6 are the **detailed reference** for the subagent's behavior,
maintained as individual reference files in `references/` and embedded in
condensed form in the subagent prompt template. The prompt template is
the executable version; the reference files are the authoritative specs.

> **Read** from `"$SKILL_DIR/references/"` as needed:
> - `references/implement-spec.md` — Step 4: Implementation rules
> - `references/health-gate-spec.md` — Step 5: Health check and investigation
> - `references/verification-spec.md` — Step 5b: Feature correctness checks
> - `references/cleanup-spec.md` — Step 5c: Post-verification cleanup
> - `references/review-spec.md` — Step 6: Code review

---

## Step 7: Commit outcome

Use the MODIFIED and CREATED lists from the subagent's
`---MSTACK-RESULT---` block. These are the files to stage.

### 7a. On success

1. Update `$NEXT` frontmatter:
   - `status: pending` → `status: done`
   - Add `completed: <YYYY-MM-DD>`
   - Add `reviewed: false` (the human hasn't seen this yet)
   - Add `qa: automated` (the verification gate passed: typecheck/lint/tests)

2. Append an `## Implementation Notes` section to the plan file (after
   the last existing section). Build it from the subagent's result block:

   ```markdown
   ## Implementation Notes

   <SUMMARY from result block>

   **Files changed:**

   - `path/to/modified.ts` (modified)
   - `path/to/created.ts` (created)

   **Commit:** `<commit hash first 7 chars>` — `<commit message first line>`
   ```

   The SUMMARY comes from the subagent's `---MSTACK-RESULT---` block.
   List every file from MODIFIED (labeled "modified") and CREATED
   (labeled "created"). The commit hash line is filled in after step 3
   below — write a placeholder, then update it after committing.

3. Commit by explicit file list (never `git add .`):
   ```bash
   git add <MODIFIED + CREATED from subagent result, including the plan>
   git commit -m "<conventional message>"
   ```

   Conventional message: `type(scope): subject` with 1-3 sentence body
   and `Refs: docs/plans/<file>` trailer. Type: fix/feat/chore.
   Scope: most-affected package. Example:
   `fix(lookbook-api): only mark scraped items 'ready' when usable`

4. Backfill the commit hash into the plan's Implementation Notes section.
   Replace the placeholder with the actual short hash and message:
   ```bash
   COMMIT_HASH=$(git rev-parse --short HEAD)
   COMMIT_MSG=$(git log -1 --format=%s)
   ```
   Update the `**Commit:**` line in `$NEXT`, then amend the commit:
   ```bash
   git add "$NEXT"
   git commit --amend --no-edit
   ```

5. Print: `[mstack] └─ Committed: <commit message first line>`

6. Archive: `mkdir -p "$(dirname "$NEXT")/archive"` then
   `git mv "$NEXT" "$(dirname "$NEXT")/archive/"` and
   `git commit -m "chore: archive plan ${PLAN_ID} (done)"`.
   Scripts scan `archive/` so blocked-by resolution still works.

7. Tag: `git tag "mstack/plan-${PLAN_ID}-done"`

8. Clean up manifest on goal completion: if all scoped IDs are now
   terminal (done or failed), delete the manifest:

   ```bash
   if [ -n "$SCOPE_IDS" ]; then
     MANIFEST_DATA=$(bash "$SKILL_DIR/scripts/manifest.sh" read 2>/dev/null) || true
     if [ -n "$MANIFEST_DATA" ]; then
       SCOPE_COUNT=$(echo "$MANIFEST_DATA" | jq '.scope_ids | length')
       TERMINAL_COUNT=$(echo "$MANIFEST_DATA" | jq '.terminal_ids | length')
       if [ "$TERMINAL_COUNT" -ge "$SCOPE_COUNT" ]; then
         bash "$SKILL_DIR/scripts/manifest.sh" delete
       fi
     fi
   fi
   ```

9. **Do not push.** The user pushes when ready.

### 7b. On failure

The subagent already reverted on failure (STEP C). Verify MODIFIED and
CREATED files are back to HEAD state. If any remain dirty and are not in
PRE_DIRTY, revert them: `git checkout HEAD -- <file>` for MODIFIED,
`rm -f <file>` for CREATED. Files in both MODIFIED and PRE_DIRTY: leave
alone, note in failure-commit message.

1. Update `$NEXT` frontmatter: `status: failed`, add
   `failed-reason:` and `failed-at: <YYYY-MM-DD>`.
2. Commit: `git add "$NEXT"` then
   `git commit -m "chore(plan ${PLAN_ID}): failed (<short reason>)"`
3. Print `[mstack] └─ FAILED: <one-line reason>` if subagent did not.
4. **Do not push.**

## Step 7c: Learnings: extract

After either success (7a) or failure (7b), extract 0-2 learnings from this
iteration. Only extract patterns that are:
- **Non-obvious**: can't be inferred from `AGENTS.md`/`CLAUDE.md` or file names
- **Reusable**: would help a future plan touching the same area
- **Concrete**: names specific files, patterns, or constraints

**On success**, look for:
- Architectural patterns ("services in this project always go through the queue")
- Conventions the gate enforced ("imports must use .js extension")
- Dependencies discovered ("module X requires Y to be initialized first")

**On failure**, look for:
- Pitfalls ("the ORM doesn't support X, don't try it")
- Environmental constraints ("this test suite needs the DB running")
- Architectural blockers ("can't do X without first refactoring Y")

For each learning, write it via the learnings script (handles dedup/merge
automatically, bumping confidence if the key already exists):

```bash
bash "$SKILL_DIR/scripts/learnings.sh" append '{"key":"<slug>","insight":"<one sentence>","type":"<pattern|pitfall|convention|dependency>","evidence":"plan-${PLAN_ID}","confidence":7,"refs":["<file paths>"],"created":"<YYYY-MM-DD>","last_verified":"<YYYY-MM-DD>"}'
```

If nothing worth extracting: skip silently.

## Step 7c2: Update execution manifest

After each plan completes (success or failure), update the execution
manifest if a scoped run is active:

```bash
if [ -n "$SCOPE_IDS" ]; then
  # Derive terminal IDs by scanning all scoped plan files for done/failed status
  TERMINAL_IDS=""
  for _sid in ${SCOPE_IDS//,/ }; do
    _sid_clean="$(echo "$_sid" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -z "$_sid_clean" ] && continue
    _plan_file="$(bash "$SKILL_DIR/scripts/manifest.sh" read 2>/dev/null | jq -r ".plans[\"$_sid_clean\"].file // \"\"")"
    [ -z "$_plan_file" ] && continue
    _plan_status="$(awk '/^---/{fm++;next} fm==1 && /^status:/{sub(/^status:[[:space:]]*/,"");print;exit}' "$_plan_file" 2>/dev/null || true)"
    if [ "$_plan_status" = "done" ] || [ "$_plan_status" = "failed" ]; then
      [ -n "$TERMINAL_IDS" ] && TERMINAL_IDS="$TERMINAL_IDS,$_sid_clean" || TERMINAL_IDS="$_sid_clean"
    fi
  done
  bash "$SKILL_DIR/scripts/manifest.sh" update "$PLAN_ID" "$TERMINAL_IDS"

  # Run anomaly detection after manifest update (iteration_bound, repeat_pick, etc.)
  ANOMALY_REASON="$(bash "$SKILL_DIR/scripts/manifest.sh" check 2>/dev/null)" || true
  if [ -n "$ANOMALY_REASON" ]; then
    # handoff.sh write-anomaly emits the existing ANOMALY signal and preserves the manifest.
    bash "$SKILL_DIR/scripts/handoff.sh" write-anomaly "$ANOMALY_REASON"
    # Manifest is NOT deleted on anomaly (preserved for debugging)
    exit 1
  fi
fi
```

## Step 7d: Write checkpoint (mstack-checkpoint)

After every plan completion (success or failure), construct checkpoint JSON
and write it via the checkpoint script. The checkpoint carries **facts, not
reasoning** (see mstack-checkpoint for the full schema).

Construct JSON with three sections:
- **attempts**: append this plan's outcome with observable errors
- **user_context**: preserve from previous checkpoint (accumulates)
- **counters**: update plans_completed/failed/remaining, health trend,
  investigate strikes used

Write it:

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" write '<constructed JSON>'
```

Key principle: a fresh session gets evidence and forms its own conclusions.
Never write interpretations or hypotheses into checkpoint data.

## Step 7e: Worktree cleanup

After every plan completion (success or failure), clean up any stale
worktrees left behind by sub-agents (code-review, investigate, or any
Agent call with `isolation: "worktree"`).

```bash
STALE_WORKTREES=$(git worktree list --porcelain | grep "^worktree " | grep -v "$(git rev-parse --show-toplevel)$" | sed 's/^worktree //')
if [ -n "$STALE_WORKTREES" ]; then
  echo "$STALE_WORKTREES" | while read -r wt; do
    git worktree unlock "$wt" 2>/dev/null || true
    git worktree remove "$wt" --force 2>/dev/null || true
  done
  git worktree prune 2>/dev/null || true
fi
```

If worktrees are found and cleaned, log: "Cleaned N stale worktree(s)."
If none found, skip silently. This step is non-blocking; cleanup failures
do not fail the plan.

## Step 8: Signal completion

`/goal` owns the loop. mstack-run is a single-iteration worker. After
each plan, output a clear signal so `/goal` can decide whether to continue.
In Codex, the active goal should continue invoking `mstack-run` until it sees
`Backlog clear.`, `[mstack] Done.`, `[mstack] ANOMALY:`, or a bail/error
message. In Claude Code, the same signals are consumed by the `/goal` loop.

### If the backlog is empty (Step 2 found nothing)

Run the **final validation pass**, then the **simplify pass** and
**completion notification**, then print "Backlog clear." and exit.
`/goal` will see this and stop.

#### Final validation pass

> **Read** `"$SKILL_DIR/references/final-validation.md"` before proceeding.
> Cross-plan regression detection: runs health-check.sh without PLAN_ID,
> attributes regressions via git blame. Failure does NOT mark plans failed.

#### Goal-complete summary

After the final validation (pass or fail), after the simplify pass and
completion notification, print the goal-complete summary:

```
[mstack] Done. <N> completed, <N> failed, <N> skipped. Run /mstack-changelog to review.
```

Count completed/failed/skipped from the plan files' `status:` fields.
If the final validation failed, append " (but final validation failed)"
to the summary line.

**Simplify pass:** Run the mstack-code-review simplification logic
(Step 4b) scoped to `git diff $(git merge-base $DEFAULT_BRANCH HEAD)..HEAD`.
This catches cross-plan reuse opportunities. If simplifications are applied
and the gate passes, commit them:

```bash
git add <simplified files>
git commit -m "chore: simplify code from plan session

Post-loop polish: reuse consolidation, clarity fixes, convention alignment.
"
```

**Completion notification:** If a notification MCP tool is configured in
the allowed-tools above, send:

```
"mstack-run: backlog clear. N plans done this session. Run /mstack-changelog to see what shipped."
```

If no notification tool is configured or it errors, silently skip.

### If more plans remain

End your reply with one terse line:

```
plan ${PLAN_ID}: <done|failed:reason>
```

`/goal` will start a new turn, AGENTS.md/CLAUDE.md routing will invoke
mstack-run again, and the next plan gets picked up.

### If a bail check failed (Step 1)

Print the bail reason and exit. `/goal` will see the error and stop.

## Recovery from a failed iteration's commit

If a `chore(plan N): failed (...)` commit lands but the user wants to
re-attempt, they edit the plan frontmatter back to `status: pending` and
re-run `/mstack-run`. The skill is idempotent on plan state; only
the picker's `status: pending` filter matters.
