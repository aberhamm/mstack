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
  Also accepts plan names/slugs in explicitly-delimited form — a quoted
  string (`"plan-ref resolver"`) or a `name:`/`plan:`-prefixed token
  (`name:webhook-retry`) — resolved to the matching ID; ambiguous or
  archived-only names abort with a diagnostic rather than guessing. When no
  IDs or names are provided, falls back to picking the next unblocked plan
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
  investigation (category-aware strikes: 3 per root cause category, max 3
  categories, 9 total), abandon the iteration and rollback (Step 7). Never
  commit broken code to `main`.
- **Never `--no-verify`, `--no-gpg-sign`, or any commit/push escape hatch.**
- **Never rebase, and never amend a PRIOR commit.** Each iteration is a
  single forward commit. The one sanctioned exception is Step 7a step 6's
  hash-backfill `git commit --amend --no-edit` of the commit this same
  iteration just created — nothing else may be amended.
- **Never delete a plan file.** Set `status: failed` instead.
- **Never implement a plan in the parent context.** Steps 4-6 always run
  inside a delegated implementation agent (Step 3d). The parent orchestrates
  — picks, gates, parses the result block, commits — and reads no source
  files of its own to do the work. "It's a small plan" is not an exemption:
  the parent's context is the scarce resource across a multi-plan loop, and
  a plan that looked small is exactly the one whose inline implementation
  poisons the next five iterations.

## Step 1: Startup

Run bail checks and load configuration. **Do not schedule another
iteration on bail**; the loop ends here.

### Auto-init

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-run" ] && { SKILL_DIR="${_skill_base}/mstack-run"; break; }
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
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

### Enforcement-hook guard (plan 038)

After the bail checks pass, verify the non-optional enforcement hook is
installed and current — an agent (or a stale checkout) that removed or edited
the hook is caught here, on the next run, rather than being able to route
around the write-time barrier:

```bash
bash "$SKILL_DIR/scripts/review-gate.sh" assert-hook-installed
```

On a nonzero exit (`EXIT_GATE_HOOK_MISSING`, 26) the command already printed
what is wrong (`core.hooksPath` unset, or a missing/stale hook file) and the
exact remedy. **Bail** — do not implement a plan without the barrier in place.
Print the remedy plainly so an un-migrated repo is not confusing:

```
[mstack] BAIL: enforcement hook missing or stale. Install it with `mstack-init`
(or `./setup` from the mstack source repo), which sets core.hooksPath=.githooks
and installs the pre-commit/pre-push hooks, then re-run.
```

This is a startup bail like the others in Step 1: do not schedule another
iteration.

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
  crashed mid-plan. This plan is not the one you're about to read, so its
  title isn't already in hand — resolve `${plan_id}: <title>` via
  `plan_label` (`source "$SKILL_DIR/scripts/lib.sh"; plan_label "$plan_id"`)
  before citing it. Log: "Previous session crashed during plan ${plan_id}:
  <title>. Plan remains in-progress; pick-next will skip to the next plan."
- Read `counters` for continuity (plans completed so far, health trend).

### Prune stale checkpoints

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" prune
```

## Step 1b: Parse plan IDs and goal name from arguments (scoped execution)

Parse `$ARGUMENTS` for plan IDs, explicitly-delimited plan names, and an
optional goal name to enable scoped execution. When plan IDs or names are
provided, only those plans are considered for execution. When a goal name
is provided, matching plans are discovered automatically. When none of
these is provided, fall back to the full backlog (backward compatible).

Process `$ARGUMENTS` in this strict order:

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
  A numeric token is a numeric token by definition (all digits), so it
  never routes through Step 2b's name matcher below.

Step 2b — Explicit name-token extraction (HARD RULE, not guidance):
  Names in scope position must be EXPLICITLY DELIMITED. Only these two
  forms are recognized as a plan-name reference:
    - A quoted substring literally present in $ARGUMENTS:
      "plan-ref resolver" or 'plan-ref resolver'
    - A `name:`/`plan:`-prefixed token, colon-attached with no space:
      name:webhook-retry, plan:031-my-slug
  A bare, undelimited leftover word is NEVER treated as a name reference
  here — even if it happens to whole-token match a plan's title or slug.
  This is the exact failure the eng review flagged: "finish the resolver
  plan" must NOT silently auto-scope to plan 031 just because "resolver"
  whole-token matches its slug. Only a quoted or prefixed form triggers
  resolution.

  For each delimited reference found, resolve it via the plan-031 resolver
  (do this before Step 3's stop-word removal, and strip the matched
  delimited text — quotes/prefix plus content — out of the working
  argument string so it is never re-processed as a stop word or a goal
  token):
  ```bash
  source "$SKILL_DIR/scripts/lib.sh"
  ref_out="$(resolve_plan_ref "<slug-or-title-fragment>")"; ref_rc=$?
  ```
  - `ref_rc` = 0: the resolver printed "<bare_id> <status>" (two
    space-separated fields). If `status` is `active`, append `<bare_id>`
    to `SCOPE_IDS`. If `status` is `archived`, ABORT (see below) — a name
    that matches only a completed plan is never silently resolved to a
    done ID that would later trip pick-next's "all scoped plans done".
  - `ref_rc` = `EXIT_REF_AMBIGUOUS` (21): ABORT. The resolver already
    printed each candidate as `NNN: Title` to stderr. Print a message that
    distinguishes "this looked like a plan name and was ambiguous" from a
    hard error, and points at the numeric form as the unambiguous path:
    ```
    [mstack] ERROR: name '<ref>' looked like a plan name but matched more
    than one plan (candidates printed above). Use one of the numeric IDs
    instead, or narrow the name.
    ```
  - `ref_rc` = `EXIT_REF_NOT_FOUND` (22): ABORT. Print:
    ```
    [mstack] ERROR: name '<ref>' did not match any plan (active or archived).
    ```
  - Archived-only match: ABORT. Print (cite via `plan_label`):
    ```
    [mstack] ERROR: name '<ref>' matches only a completed plan: NNN: Title.
    Use its numeric ID if you intend to re-run it deliberately.
    ```
  Any ABORT here exits without picking a plan; `/goal` will see the error
  and stop. No fallback-to-backlog on a delimited name that fails to
  resolve cleanly — the user was explicit, so a clean failure beats a
  silent guess.

Step 3 — Stop-word removal:
  Remove these stop words from the remaining (non-numeric, non-consumed-name)
  tokens:
    complete, mstack, plans, plan, are, done, failed, or, the,
    all, pending, run, execute, finish, goal
  Note: /goal itself is not in $ARGUMENTS (the /goal evaluator strips it).

Step 4 — Goal detection:
  After removing stop words, numeric tokens, and consumed name references,
  check remaining tokens:
    - Zero tokens remain → no goal, proceed with SCOPE_IDS only.
    - Exactly one non-stop-word non-numeric token remains → GOAL_NAME.
      Example: "complete webhook-retry mstack plans" → GOAL_NAME="webhook-retry"
      This matches the plan's `goal:` frontmatter field by exact string
      equality (Goal discovery below) — a distinct, pre-existing mechanism
      from the Step 2b name resolver. It is NOT plan-title/slug fuzzy
      matching, so this bare-leftover-token path was never the failure
      mode Step 2b guards against; it already fails closed today (Goal
      discovery aborts with "no plans found with goal: <GOAL_NAME>" when
      the token doesn't match any plan's goal).
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
  scope error. Cite both plans via `plan_label` (`NNN: Title`), not their
  bare ids — except the `add <id> to the scope` instruction, which stays a
  bare id because it's the literal `$SCOPE_IDS` argument syntax the user
  would type. Print:

  ```
  [mstack] ERROR: Plan 009: Stripe webhook integration is blocked by plan
  005: Add authentication middleware, which is not in the execution scope
  and is not done. Either add 005 to the scope or complete it first.
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
| 10 | All done | Run final validation pass + simplify pass + completion notification (Step 8), print "Backlog clear." and exit |
| 11 | Scoped ID not found | Print stderr diagnostic, exit iteration |
| 12 | All blocked | Print stderr diagnostic (blocked deps), exit iteration |
| 13 | Dependency cycle | Print stderr diagnostic (cycle path), exit iteration |
| 14 | Duplicate IDs | Print stderr diagnostic (dup files), exit iteration |
| 21 | Ambiguous scope name (plan 031's `resolve_plan_ref`) | Print stderr candidate list, exit iteration. Not expected in normal `mstack-run` flow — Step 1b already resolves names to numeric IDs before `SCOPE_IDS` reaches the picker — but the picker also accepts names directly when invoked standalone. |

Handle each exit code:

```
case $PICKER_EXIT in
  0)  # Plan found — proceed with NEXT
      ;;
  10) # All plans (or all scoped plans) are done
      # Run the final validation pass, then the simplify pass and
      # completion notification (Step 8),
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
  21) # Ambiguous scope name (not expected here — Step 1b resolves names
      # before calling the picker — but handled defensively)
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
[mstack] Backlog: N pending, M blocked, K done, J failed, S skipped
```

Read all plan files, tally by `status:` field (pending, blocked, done,
failed, in-progress, skipped). Print this line once per mstack-run
invocation, before the first plan starts or before reporting "Backlog
clear." `skipped` plans are deliberately retired and never picked; count
them here so the tally matches Step 8's goal-complete summary, which
already reports skipped.

If `PICKER_EXIT` is 10 (all done): run the final validation pass, then the
simplify pass and completion notification (Step 8), print "Backlog clear."
and exit. The `/goal`
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
#
# Capture the baseline with the shared `porcelain_paths` normalizer (NOT the
# old `awk '{print $2}'`, which dropped rename targets, mangled spaced/quoted
# paths, and collapsed untracked directories) and PERSIST it to a gitignored
# file. Shell state does not survive to Step 7a — which runs
# `assert-work-committed` in a separate process — so the machine-readable
# baseline must live on disk. `.mstack/` is fully gitignored, so the baseline
# file never itself shows up in porcelain. Key the filename by the NORMALIZED
# plan id so the writer here and the reader in `assert-work-committed` agree.
source "$SKILL_DIR/scripts/lib.sh"
ensure_mstack_dir
PLAN_ID_NORM="$(normalize_id "$PLAN_ID")"
PRE_DIRTY_FILE="$REPO_ROOT/.mstack/pre-dirty-${PLAN_ID_NORM}.txt"
porcelain_paths > "$PRE_DIRTY_FILE"
PRE_DIRTY="$(cat "$PRE_DIRTY_FILE")"
echo "Pre-existing dirty files (off-limits to skill rollback; baseline persisted to $PRE_DIRTY_FILE):"
echo "$PRE_DIRTY"
```

Keep `$PRE_DIRTY` in mind throughout. If you need to edit a file that's
in this list, that's a real conflict. Flag it in the iteration's commit
message and let the user reconcile. The persisted `$PRE_DIRTY_FILE` is the
machine baseline Step 7a's `assert-work-committed` subtracts the completion-time
porcelain set against; the human-readable `$PRE_DIRTY` notion above is the same
set, just for the prose here.

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
3. Print (cite the plan as `${PLAN_ID}: <title>` — you already have `<title>`
   from Step 3's read of `$NEXT`; the `/mstack-plan-doctor` argument stays a
   bare id, since it's the literal command syntax):
   ```
   ${PLAN_ID}: <title> — blocked (incomplete spec). Run /mstack-plan-doctor ${PLAN_ID} to fix.
   ```
4. Return the Step 8 signal (schedule next iteration); `/goal` drives the
   next iteration. This invocation does exactly one plan — do NOT implement
   another plan here.

Do NOT attempt to implement a plan with placeholder content. The human
must fill in the spec first.

### JIT seam re-validation

After the placeholder check passes, if the picked plan's `blocked-by` deps
are all `done` (their artifacts are now REAL on disk), re-validate the plan's
upstream seam assumptions against the actual codebase. This catches a plan
whose `<!-- mstack:seam ... -->` contract diverged from what the upstream plan
actually built, BEFORE implementation starts on a false premise.

```bash
bash "$SKILL_DIR/scripts/seam-check.sh" "$NEXT"
```

`seam-check.sh` parses the plan's machine-readable `mstack:seam` block (the
contract emitted by plan-doctor, grammar in
`skills/mstack-plan-doctor/references/seam-contracts.md`) and checks each
`assumed:` entry that carries a `file:` (VERIFIABLE): the file must exist and,
if a `shape:` is present, the shape token must appear within that file.
Entries with no `file:` are UNVERIFIABLE and never block. It is deterministic
and fast (no external model). Exit codes:

- **`0`** — clean, no seam block, or all assumed entries UNVERIFIABLE. Proceed
  to implementation unchanged.
- **`20`** — confirmed stale seam (a verifiable file is missing or its
  `shape:` token is absent). Block the plan exactly like the incomplete-spec
  path above:
  1. Set the plan's `status: in-progress` → `status: blocked` and add
     `needs-review: eng`.
  2. Commit only the plan file:
     ```bash
     git add "$NEXT"
     git commit -m "chore(plan ${PLAN_ID}): blocked, stale seam"
     ```
  3. Print the seam-check diagnostic plus (cite as `${PLAN_ID}: <title>`; the
     `/mstack-plan-doctor` argument stays a bare id — command syntax):
     ```
     ${PLAN_ID}: <title> — stale seam — <assumed> not found / differs; run /mstack-plan-doctor ${PLAN_ID}
     ```
  4. Return the Step 8 signal (schedule next iteration); `/goal` drives the
     next iteration. This invocation does exactly one plan — do NOT implement
     another plan here.

Plans with no `blocked-by`, no seam block, or only UNVERIFIABLE entries flow
through unchanged (exit 0), so this is backward compatible.

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
matched learnings as implementation guidance, citing the plan as
`${PLAN_ID}: <title>` (already in hand from Step 3):

```
Relevant learnings for ${PLAN_ID}: <title>:
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

### Approved-but-uncommitted gate (plan 037)

Immediately before delegating to the implementation agent — not cached from
earlier in the run, checked fresh here at execution start:

```bash
bash "$SKILL_DIR/scripts/review-gate.sh" assert-committed "$NEXT"
```

This is plan 037's "approved ⇒ committed" invariant: a plan that has a
recorded `reviews:` verdict must not be executed against a dirty tree for
its own plan file. In the normal case this is a no-op — the approval-commit
already landed at `mstack-plan-doctor` Step 5, before the plan was ever
picked up here — so this check should see a clean tree. It exists to catch
the rare case where the approval commit was skipped, reverted, or the plan
file was hand-edited after approval.

- Exit `0` (including the "exempt: no recorded review verdict" case for a
  plan with no `reviews:` entry) → proceed to construct the Agent prompt.
- Nonzero (`EXIT_GATE_NOT_COMMITTED`, 25) → do **not** run the implementation
  agent against a dirty approval. Commit the plan file now, by explicit file
  list, no push:
  ```bash
  git add "$NEXT"
  git commit -m "chore(plan ${PLAN_ID}): commit approval before execution"
  ```
  Then re-run `assert-committed` once. If it now exits 0, proceed. If it
  still fails (e.g. the dirty state isn't just the plan file's own frontmatter
  and committing it doesn't resolve the check), treat this like the JIT seam
  block above: set `status: blocked`, add `needs-review: eng`, commit only
  the plan file with `git commit -m "chore(plan ${PLAN_ID}): blocked, approval uncommitted"`,
  print `${PLAN_ID}: <title> — blocked (approved but uncommitted, could not
  auto-heal); run /mstack-plan-doctor ${PLAN_ID}`, and return the Step 8
  signal (schedule next iteration) rather than implementing this plan.

## Step 3d: Delegate to implementation agent

Steps 4-6 are noisy (many file reads/edits, health runs, review agents).
Run them inside a **single implementation agent/subagent** so the parent
context stays lean across multi-plan loops. The parent sees only the
structured result.

**This delegation is mandatory, not an optimization.** There is no plan
size, no "this is a one-line edit", and no "I already have the file open"
that licenses the parent to do Steps 4-6 itself. If you find yourself about
to Read a source file named in the plan's spec, or to Edit anything other
than the plan's own frontmatter, you have skipped Step 3d — stop and spawn
the agent. The parent's only writes this iteration are plan-file
bookkeeping and the Step 7 commit.

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

- **`pass`** → proceed to Step 7a, whose **first** action re-parses this block's
  health fields (`assert-health-result`) and rejects the completion if the
  health gate did not actually run and pass. A `pass` claim is not taken on
  trust. Use MODIFIED + CREATED + DELETED for the commit (DELETED paths are
  `git rm`'d / staged as removals) and SUMMARY for the implementation notes.
- **`fail`** → the agent already reverted and printed the `[mstack] └─ FAILED`
  line. Proceed to Step 7b (update plan status and commit only the plan file).
- **`blocked`** → the agent already updated the plan. Commit the plan
  file and signal Step 8; this iteration ends there, and `/goal` picks the
  next plan in a fresh iteration.

**Skipped plans (blocked by failed dependencies):** If pick-next finds a
plan whose `blocked-by` includes a plan with `status: failed`, that plan
cannot run. `<id>` here is the failed dependency, not the skipped plan
itself, so resolve its title via `plan_label <id>` before citing it. Print:

```
[mstack] └─ SKIPPED: blocked by failed plan <id>: <title>
```

Update the skipped plan's status to `status: blocked` and add
`blocked-reason: dependency failed (plan <id>: <title>)`. Commit only the
plan file and continue to Step 8.

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

Use the MODIFIED, CREATED, and DELETED lists from the subagent's
`---MSTACK-RESULT---` block. These are the files to stage — MODIFIED and
CREATED as content adds, DELETED as removals (`git rm`).

### 7a. On success

**Full linear order (do NOT interleave the steps — 043 inserts the health-result
check at the very top, 036 the review gate, 039 the work-committed check near
the end, with commits in between):**

**0. `assert-health-result` (043)** → 1. `assert-completable` (036) →
2. `assert-no-downgrade` (036) →
3. frontmatter `status: done` write → 4. append Implementation Notes →
5. stage `MODIFIED + CREATED + DELETED` and commit (step 5) →
6. backfill-hash `git commit --amend` (step 6, re-touches `$NEXT`) →
**6b. `assert-work-committed` (039)** → 7. print the `└─ Committed:` line →
8. archive `git mv "$NEXT" archive/` and its commit (transiently dirties,
then re-cleans the tree) → 9. tag.

Placing 039's `assert-work-committed` **after the amend and before the archive
`git mv`** means it inspects exactly the post-work committed state: the declared
work is already in the commit, and the archive commit that follows re-cleans the
tree before the tag, so the (optional, best-effort) pre-push dirty-tree tag
guard still sees a clean tree.

**Commit-on-completion rule (orchestrator-facing, not convention):** the
completing orchestrator MUST commit all declared work product
(`MODIFIED + CREATED + DELETED`) before completion. A working tree carrying
plan-attributable dirt at completion is an invalid terminal state and fails the
plan — the plan is not "done with a dirty tree." `assert-work-committed`
enforces this on the honest path; on failure you HALT and REPORT the stray
paths and do **not** auto-`git add` them (that would be the forbidden
`git add .` sweep) and do **not** create the `mstack/plan-${PLAN_ID}-done` tag.

0. **Health-result check (fail closed, plan 043) — the FIRST action of the
   success path, before the review gate and before any frontmatter write.**
   A `STATUS: pass` result block is only trustworthy if the health gate
   actually ran and actually passed. Do not eyeball the block — parse it:

   ```bash
   printf '%s\n' "$RESULT_BLOCK" > ".mstack/result-${PLAN_ID}.txt"
   bash "$SKILL_DIR/scripts/result-gate.sh" assert-health-result ".mstack/result-${PLAN_ID}.txt"
   ```

   where `$RESULT_BLOCK` is the subagent's `---MSTACK-RESULT---` block exactly
   as returned (`.mstack/` is gitignored, so this scratch file is never staged).

   The check **rejects** (exit `EXIT_RESULT_HEALTH_INVALID`, 30) a `pass` result
   whose `HEALTH_VERDICT` is missing, unparseable, or anything other than `PASS`
   or `NONE-DECLARED`, or whose `HEALTH_COMPOSITE` is missing or not a number
   (`n/a` is accepted only alongside `NONE-DECLARED`). `FAIL` and `REGRESSED`
   are rejected — the worker's own contract routes both to the failure path, so
   pairing either with `STATUS: pass` is incoherent. `NO-TOOLS` is rejected —
   the health gate found nothing and the repo never declared it has none.
   `SKIP` is rejected — it is not a legal verdict, and a worker inventing it
   around a crashed gate is the exact failure this check exists to catch.

   On nonzero exit: **abort completion.** Do not write `status: done`, do not
   archive, do not tag. Treat it as a Step 7b failure — the plan's changes were
   not validated by a health gate that actually ran, so they are not safe to
   land: revert any uncommitted changes not in `PRE_DIRTY`, set
   `status: failed` with `failed-reason: health-gate-unavailable`, commit only
   the plan file, print
   `${PLAN_ID}: <title> — FAILED (health result not verifiable: <reason>)`, and
   continue to Step 8.

   **Why this is the spine, and why it is not prose.** The original defect was
   an LLM improvising `HEALTH_VERDICT: SKIP` around a crashed gate it had no
   branch for, and Step 7a trusting it. `subagent-prompt.md` now has that
   branch — but instructing the LLM harder is the same material that already
   failed. This parse is what actually enforces the rule: a worker that
   improvises again is caught by a parser, not trusted by a reader.

1. **Gate check (fail closed) — after the health-result check, before any
   frontmatter write, archive, or tag.** Run:
   ```bash
   bash "$SKILL_DIR/scripts/review-gate.sh" assert-completable "$NEXT"
   ```
   On nonzero exit: **abort completion**, following the same blocked-outcome
   idiom as Step 3b/the JIT seam re-check above (not a Step 7b failure — the
   plan isn't broken, a review is just outstanding, so never set
   `status: failed`):
   1. Do not append Implementation Notes, do not run the Step 5/6 commit,
      do not archive, and do not create the `mstack/plan-${PLAN_ID}-done` tag.
   2. Extract every still-open type from the command's stderr (one
      `not completable: review '<type>' has no passing record` line per
      missing type) and set `$NEXT`'s frontmatter: `status: pending` (or
      `in-progress`) → `status: blocked`, and `needs-review:` to the
      comma-joined list of those types (e.g. `eng` or `eng,code`). This is
      the same field `pick-next.sh` already checks — setting it here is
      re-using the picker's existing skip mechanism (out of scope for this
      plan to change), not inventing a new one, so the picker does not
      re-select and re-implement this same plan next iteration. Note
      `needs-review` can now carry `code` alongside `eng`/`design`/`ceo`: a
      `code`-only gate (an unresolved critical/high finding from Step 6) has
      no automated remediation path, so it lands as a `needs-review` tag a
      human must clear manually (re-run `mstack-code-review` or fix and
      re-record) — `mstack-plan-doctor` Step 5 only auto-runs the
      eng/design/ceo review skills.
   3. Commit only the plan file:
      ```bash
      git add "$NEXT"
      git commit -m "chore(plan ${PLAN_ID}): blocked, review gate open"
      ```
   4. Print a hard error naming the missing review(s) and how to clear each
      (cite as `${PLAN_ID}: <title>`):
      ```
      ${PLAN_ID}: <title> — blocked (review gate open: <type>[,<type>...]).
      Run the named review (plan-eng-review / plan-design-review /
      plan-ceo-review via /mstack-plan-doctor ${PLAN_ID}, or re-run
      mstack-code-review for a `code` gate) to record a passing verdict —
      never self-clear the gate or hand-write a passing record.
      ```
   5. Return the Step 8 signal (schedule next iteration); `/goal` drives the
      next iteration. This invocation does exactly one plan — do NOT
      implement another plan here.

   This check is **anti-forgetfulness, not anti-adversary**: it only stops an
   agent that runs Step 7a honestly. An agent that skips Step 7a and
   hand-writes `status: done` + `git tag` bypasses it entirely; that hole is
   closed at the write layer by the plan-038 git hook (`.githooks/pre-commit`
   + `pre-push`, installed via `core.hooksPath` and verified at startup by the
   Step 1 `assert-hook-installed` guard), which rejects such a commit/tag
   regardless of how it was produced. Step 7a is the honest-path layer; the
   hook is the enforcement layer. See the Layered Enforcement Model in
   `AGENTS.md`.

   **Fixture/smoke exemption:** `bin/mstack-codex-smoke`'s fixture plan
   (`001-create-hello`) is authored with `needs-review: none` and no
   `review-required`, so it has an empty required set and
   `assert-completable` exits 0 for it — the gate is naturally a no-op for
   smoke fixtures with nothing to record. No path-based special-casing is
   needed or added; do not add one.

   **Why this can realistically fire in the honest path.** `pick-next.sh`
   already skips `needs-review != none` plans, and `mstack-plan-doctor` Step 5
   only clears `needs-review` after recording an eng/design/ceo verdict — so
   by the time a plan reaches Step 7a via the normal picker, those three types
   are already satisfied (or were never required) in the overwhelming common
   case. The realistic trigger is the `code` type: Step 6 (code review) runs
   on every plan and records `fail` when a critical/high finding survives
   unfixed — `assert-completable` then refuses completion even though
   `needs-review` was never involved for `code`. That is exactly the case
   this abort path exists to catch.

2. Also before any frontmatter write in this step that touches review state
   (`reviewed`, `review-required`, `reviews`), run:
   ```bash
   bash "$SKILL_DIR/scripts/review-gate.sh" assert-no-downgrade "$NEXT"
   ```
   On nonzero exit, abort the same way as step 1 (leave `$NEXT` untouched,
   report the downgrade reason). At Step 7a this call is normally **inert**:
   `reviewed: false` (added in step 3 below) is a fresh add — a plan reaching
   completion for the first time has no `reviewed` field in HEAD yet, so
   there is nothing to downgrade from. The check's real job — refusing a
   `reviewed: true -> false` edit — protects LATER out-of-band edits to an
   already-completed, human-reviewed plan; that path is exercised by a
   dedicated fixture, not by Step 7a itself. Wire the call anyway so the
   invariant is asserted on every completion rather than assumed.

3. Update `$NEXT` frontmatter:
   - `status: in-progress` → `status: done` (Step 2 already claimed the plan
     as `in-progress`; it is never still `pending` here)
   - Add `completed: <YYYY-MM-DD>`
   - Add `reviewed: false` (the human hasn't seen this yet)
   - Add `qa: automated` (the verification gate passed: typecheck/lint/tests)

4. Append an `## Implementation Notes` section to the plan file (after
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
   List every file from MODIFIED (labeled "modified"), CREATED
   (labeled "created"), and DELETED (labeled "deleted"). The commit hash line
   is filled in after step 5 below — write a placeholder, then update it after
   committing.

5. Commit by explicit file list (never `git add .`). Stage MODIFIED + CREATED
   as content, and DELETED as removals so deletion/rename-bearing plans are
   actually committable (otherwise the `D`/`R` entry would sit uncommitted and
   trip `assert-work-committed` in 6b):
   ```bash
   git add <MODIFIED + CREATED from subagent result, including the plan>
   # Stage declared deletions/renames-away, if any (skip when DELETED is empty).
   # `git add -A -- <paths>` stages an on-disk removal correctly (picks up the
   # deletion); it is the robust form for both a plain delete and the source
   # path of a rename:
   git add -A -- <DELETED from subagent result>
   git commit -m "<conventional message>"
   ```

   Conventional message: `type(scope): subject` with 1-3 sentence body
   and `Refs: <plans-dir>/<file>` trailer, where `<plans-dir>` is the
   repo's resolved plans directory (`docs/plans` or `plans`, i.e.
   `$PLANS_DIR` relative to the repo root). Type: fix/feat/chore.
   Scope: most-affected package. Example:
   `fix(lookbook-api): only mark scraped items 'ready' when usable`

6. Backfill the commit hash into the plan's Implementation Notes section.
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

6b. **Work-committed check (fail closed, plan 039) — after the amend, before
   the archive `git mv`.** The declared work is now committed; verify the tree
   carries no plan-attributable dirt beyond the plan-start baseline:
   ```bash
   bash "$SKILL_DIR/scripts/review-gate.sh" assert-work-committed "$NEXT"
   ```
   - Exit `0` → proceed to step 7 (print) and step 8 (archive/tag).
   - Nonzero (`EXIT_GATE_WORK_UNCOMMITTED`, 28) → the command printed the stray
     plan-attributable paths. **HALT completion:** do NOT auto-`git add` them
     (the forbidden `git add .` sweep would commit undeclared build junk), do
     NOT archive, and do NOT create the `mstack/plan-${PLAN_ID}-done` tag. The
     work product is incompletely committed — the plan is not done. Report the
     stray paths to the user so the missing edits can be added to the subagent's
     MODIFIED/CREATED/DELETED lists (or committed deliberately) and the plan
     re-run. A dirty plan-attributable tree fails the plan; a missing baseline
     file fails closed the same way (cannot verify ⇒ not completable). This is
     the honest-path enforcement of the commit-on-completion rule stated at the
     top of Step 7a.

7. Print: `[mstack] └─ Committed: <commit message first line>`

8. Archive: `mkdir -p "$(dirname "$NEXT")/archive"` then
   `git mv "$NEXT" "$(dirname "$NEXT")/archive/"` and
   `git commit -m "chore: archive plan ${PLAN_ID} (done)"`.
   Scripts scan `archive/` so blocked-by resolution still works.

9. Tag, ANNOTATED — the `-a -m` is load-bearing, do not "simplify" it away:
   ```bash
   git tag -a "mstack/plan-${PLAN_ID}-done" -m "plan ${PLAN_ID} done"
   ```
   A bare `git tag <name>` creates a **lightweight** tag, and `--follow-tags`
   (the very command step 11 tells the user to push with) **only pushes
   annotated tags** — so a lightweight completion tag silently never reaches
   the remote. This was live long enough to strand every `mstack/plan-*-done`
   tag from 031 through 042 on one machine, unnoticed, because nothing ever
   compared local tags against `git ls-remote`.

   The tag is still **local-only until pushed**; a plain `git push` does not
   carry it (see step 11).

10. Clean up manifest on goal completion: if all scoped IDs are now
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

11. **Do not push.** The user pushes when ready. When they do, remind them that
    a plain `git push` leaves the `mstack/plan-*-done` tags stranded locally —
    push with `git push --follow-tags`, which carries the **annotated** tags step
    9 creates.

    **`--follow-tags` is only sufficient because step 9 tags with `-a`.** It
    silently ignores lightweight tags, so if step 9 ever regresses to a bare
    `git tag <name>`, this command will keep succeeding while pushing no tags at
    all. That pairing is the whole bug — the two steps must be changed together
    or not at all.

    Tags created before that fix are still lightweight and will NOT be carried;
    push those explicitly by name (`git push origin mstack/plan-NNN-done`). To
    find them, compare local tags against the remote rather than assuming:
    ```bash
    git tag -l 'mstack/plan-*' | while read -r t; do
      git ls-remote --tags origin "$t" | grep -q . || echo "not on remote: $t"
    done
    ```

### 7b. On failure

The subagent already reverted on failure (STEP C). Verify MODIFIED, CREATED
and DELETED files are back to HEAD state. If any remain dirty and are not in
PRE_DIRTY, revert them: `git checkout HEAD -- <file>` for MODIFIED,
`git checkout HEAD -- <file>` for DELETED (this restores a file the plan
removed or renamed away — `rm -f` cannot), `rm -f <file>` for CREATED. Files
in both MODIFIED and PRE_DIRTY: leave alone, note in failure-commit message.

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

#### After the backlog clears, small follow-ups are not new plans

The moment right after `[mstack] Done.` is when the pull toward "I'll add a
plan for that" is strongest and least justified. Whatever the user asks for
next — polish the wording, rename that helper, fix the small thing the review
surfaced, delete the scaffolding this session obsoleted — **make the change
directly and commit it normally.** Do not scaffold plan `NNN+1` for an errand.

Queue a plan only if the follow-up is itself plan-sized: ordered steps, a
risky seam, a required review gate, or work the user explicitly wants
deferred to a later autonomous run. When unsure, do the small thing and offer
to queue a plan instead — an unwanted plan file costs more to retire than a
small commit costs to revert.

### If more plans remain

End your reply with one terse line, citing the plan as `${PLAN_ID}: <title>`
(already in hand from Step 3) rather than a bare id:

```
${PLAN_ID}: <title> — <done|failed:reason>
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
