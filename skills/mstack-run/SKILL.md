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

All progress output uses the `[mstack]` prefix so it is visually distinct
from the agent's working output (file reads, edits, tool calls). Progress
lines are plain text printed to the user, never written to files.

**Format rules:**
- Prefix every progress line with `[mstack]`
- Use tree-drawing characters to show milestone structure within a plan:
  - `├─` for intermediate milestones (more steps follow)
  - `└─` for the final milestone of a plan (success, failure, or skip)
- Backlog summary and plan header lines have no tree prefix (they are
  top-level, not nested under a plan)

**Reference of all progress lines (see inline instructions at each step):**

```
[mstack] Backlog: N pending, M blocked, K done, J failed
[mstack] Plan N/M: <title> (plan <id>)
[mstack] ├─ Implementing...
[mstack] ├─ Health gate: <score>/10 (<verdict>)
[mstack] ├─ Cleanup: <summary>
[mstack] ├─ Code review: <N> findings, <N> fixed
[mstack] └─ Committed: <commit message first line>
[mstack] └─ FAILED: <one-line reason>
[mstack] └─ SKIPPED: blocked by failed plan <id>
[mstack] Final validation: running full test suite...
[mstack] Final validation: <score>/10 (PASS)
[mstack] Final validation: FAILED (<which categories failed>)
[mstack] WARNING: Cross-plan regression detected. Review the failures above before pushing.
[mstack] Done. <N> completed, <N> failed, <N> skipped. Run /mstack-changelog to review.
```

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
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
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
  echo "Run: ExitWorktree { action: 'remove' }, or start a new conversation from the main repo directory."
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
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
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

## Step 1b: Parse plan IDs from arguments (scoped execution)

Parse `$ARGUMENTS` for plan IDs to enable scoped execution. When plan IDs
are provided, only those plans are considered for execution. When no IDs
are provided, fall back to the full backlog (backward compatible).

```
If $ARGUMENTS contains plan IDs (numeric tokens):
  SCOPE_IDS = extract all numeric IDs from $ARGUMENTS

  Supported formats:
    - Space-separated: "008 009 010 011"
    - Comma-separated: "008,009,010,011"
    - Mixed: "008, 009, 010, 011"
    - Range with "plans" prefix: "plans 008-011" (expands to 008,009,010,011)
    - Range without prefix: "008-011" (expands to 008,009,010,011)
    - Natural language with IDs: "complete mstack plans 008, 009, 010, 011"
      (extract only the numeric tokens)

  Pass SCOPE_IDS to pick-next.sh as a comma-separated argument.

If $ARGUMENTS is empty or contains no numeric tokens:
  SCOPE_IDS is empty; fall back to current behavior (all pending plans).
```

### Scope validation

When SCOPE_IDS is set, validate that scoped plans can actually run. For
each plan in the scope, check its `blocked-by` list:

- If a dependency is in the scope or already `status: done`, it's fine.
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

## Step 2: Pick the next plan

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
if [ -n "$SCOPE_IDS" ]; then
  NEXT=$(bash "$SKILL_DIR/scripts/pick-next.sh" "$SCOPE_IDS")
else
  NEXT=$(bash "$SKILL_DIR/scripts/pick-next.sh")
fi
```

The picker selects the lowest-priority pending plan whose dependencies are
met (lowest `priority:` first, then lowest `id:` as tiebreaker; plans
without `priority:` default to their `id:`). When SCOPE_IDS is provided,
only plans with matching IDs are considered (the SCOPE_FILTER in
pick-next.sh filters candidates before dependency sorting).

### Progress: backlog summary

Before acting on the pick result, count all plans by status and print:

```
[mstack] Backlog: N pending, M blocked, K done, J failed
```

Read all plan files, tally by `status:` field (pending, blocked, done,
failed, in-progress). Print this line once per mstack-run invocation,
before the first plan starts or before reporting "Backlog clear."

If `$NEXT` is empty: run the simplify pass and completion notification
(Step 8), print "Backlog clear." and exit. The `/goal` evaluator will
see this and stop.

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

Read `CLAUDE.md` (root + any nearer to the plan's scope). Note:
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

**Apply:** Search for learnings relevant to this plan's files and topic:

```bash
bash "$SKILL_DIR/scripts/learnings.sh" search "<keyword from plan title>"
bash "$SKILL_DIR/scripts/learnings.sh" search "<file path from plan>"
```

Run multiple searches if needed (by file path, by topic keyword). Surface
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
Run them inside a **single Agent call** so the parent context stays lean
across multi-plan loops. The parent sees only the structured result.

Construct the Agent prompt from everything gathered in Steps 1-3c. The
prompt must be self-contained; the subagent has no prior context.

```
Agent({
  description: "implement plan ${PLAN_ID}",
  prompt: <see template below>
})
```

### Prompt template

Include these sections verbatim, substituting variables:

```
You are implementing one plan for mstack-run. Follow these rules exactly.

CONTEXT
- Repo root: ${REPO_ROOT}
- Plan file: ${NEXT}
- Plan ID: ${PLAN_ID}
- Recovery point: ${RECOVERY}
- Pre-dirty files (never rollback these): ${PRE_DIRTY}
- Relevant learnings:
${LEARNINGS_OUTPUT}
- SKILL_DIR: ${SKILL_DIR}
- Scoped plan IDs: ${SCOPE_IDS} (empty = full backlog)

HARD RULES
- Never commit. Leave all changes uncommitted.
- Never push. Never --no-verify. Never amend.
- Never edit db/migrations/** unless the plan has allows-migrations: true.
- Track every file you touch in two lists: MODIFIED and CREATED.
  Print them in your final output.

STEP A: Read and gate
Read ${NEXT} end-to-end. Read CLAUDE.md for project conventions.
Verify the plan is fully specified (real acceptance criteria, real file
paths, 2+ task steps). If still template placeholders:
  1. Set status: blocked, add needs-review: eng
  2. Print RESULT:BLOCKED and stop.

STEP B: Implement
Before starting implementation, print:
  [mstack] ├─ Implementing...
Implement the plan fully. Do not abandon on size. Do not split.
The only legitimate failures: gate red after 3 strikes, architectural
blocker the plan didn't account for, or context exhaustion.

STEP C: Health check
Run: PLAN_ID="${PLAN_ID}" bash "${SKILL_DIR}/scripts/health-check.sh" run
Parse the VERDICT and COMPOSITE lines. Print:
  [mstack] ├─ Health gate: <COMPOSITE>/10 (<VERDICT>)
- PASS → continue to Step C2.
- FAIL or REGRESSED → investigate (category-aware strikes per mstack-investigate).
  If all categories exhausted, revert your changes surgically:
    git checkout HEAD -- <MODIFIED minus PRE_DIRTY>
    rm -f <CREATED>
  Print: [mstack] └─ FAILED: <one-line reason>
  Then print RESULT:FAIL with the reason and stop.

STEP C2: Verification gate
Read the plan's ## Verification section. Parse executable checks:
  [cmd] <command>: run, assert exit 0
  [assert] <command> | <expected>: run, assert stdout contains expected
  [status] <curl> -> <code>: run, assert HTTP status matches
  [browse] <path> <assertion>: browser-based check via gstack /browse skill
  [manual]: skip (log as "skipped: human review")
For [browse] checks: detect gstack (test -f browse/SKILL.md paths),
  skip with warning if not installed, start dev server if needed,
  invoke /browse, treat failures like [cmd] failures.
If no executable checks exist:
  - If plan has `verification: health-only`: skip to Step C3.
  - Otherwise: print RESULT:FAIL with reason "missing-verification-checks".
For each check (30s timeout):
  - Run it, record pass/fail + output to .mstack/evidence/plan-${PLAN_ID}/
  - If a check needs a running server, start it first (read CLAUDE.md for
    the start command), run checks, then stop it.
If ALL pass → write summary.md to evidence dir, continue to Step C3.
If ANY fail → investigate (category-aware strikes, same as health gate).
  After all categories exhausted, revert and print RESULT:FAIL.

STEP C3: Cleanup sweep
After verification passes, sweep only the files changed by this plan for
leftover artifacts. Get the changed files list:
  git diff --name-only ${RECOVERY} HEAD -- ; git diff --name-only HEAD
(Combines committed changes from the claim commit and uncommitted working
tree changes to get every file this plan touched.)

For each changed file, check for:
  - Unused imports: import/require where the imported name never appears
    elsewhere in the file
  - Dead functions: functions/classes defined but never called within the
    changed files or imported by other files in the diff
  - Debug artifacts: console.log, debugger, TODO, FIXME, HACK comments
    added during implementation
  - Orphan files: new files created but not imported/referenced by any
    other file in the project

If issues found:
  1. Fix them in the working tree
  2. Re-run health gate: PLAN_ID="${PLAN_ID}" bash "${SKILL_DIR}/scripts/health-check.sh" run
  3. If health passes, continue to Step D
  4. If health fails, revert cleanup fixes and continue to Step D with
     original passing implementation
  Print: [mstack] ├─ Cleanup: <summary of what was cleaned>

If no issues found:
  Print: [mstack] ├─ Cleanup: nothing to clean
  Continue to Step D.

The sweep is scoped only to the current plan's diff. Never touch files
outside that set.

STEP D: Code review
Proceed directly to review. After the review completes, print:
  [mstack] ├─ Code review: <N> findings, <N> fixed
where the first N is total findings above confidence 7, and the
second N is findings that were fixed. If no findings: "0 findings, 0 fixed".

Check plan frontmatter for `review: thorough`.
  - Standard (default): 1 unified reviewer (correctness + conventions + simplicity).
  - Thorough: 3 blind review agents with cross-model routing.
Discard findings below confidence 7. Fix critical/high findings.
Re-run health check after fixes. If it fails, revert the review
fixes and keep the original passing implementation.
Write review artifact to .mstack/reviews/plan-${PLAN_ID}.json.

FINAL OUTPUT: print exactly this block at the end:
---MSTACK-RESULT---
STATUS: pass | fail | blocked
PLAN_ID: ${PLAN_ID}
MODIFIED: file1.ts, file2.ts
CREATED: file3.ts
HEALTH_VERDICT: PASS
HEALTH_COMPOSITE: 9.1
VERIFICATION: pass | skip | fail
VERIFICATION_CHECKS: 3/3 passed (or "skipped, no executable checks")
FAILED_REASON: (only if STATUS is fail)
PRE_DIRTY_CONFLICTS: (files in both MODIFIED and PRE_DIRTY, if any)
---END---
```

### Parse the result

Extract the `---MSTACK-RESULT---` block from the agent's output.

- **`pass`** → proceed to Step 7a. Use MODIFIED + CREATED for the commit.
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

If the agent errors or returns no result block, treat as a failure:
revert any uncommitted changes not in PRE_DIRTY, set the plan to
`status: failed` with `failed-reason: agent-error`, and continue.

---

The steps below (4-6) are the **detailed reference** for the subagent's
behavior. They are embedded in the prompt template above in condensed
form. Keep them in sync; the template is the executable version, these
sections are the authoritative specification.

---

## Step 4: Implement (no commits yet)

**Progress:** Before starting implementation, print:
```
[mstack] ├─ Implementing...
```

Make the changes required by the plan. **Do not commit during
implementation**; uncommitted edits let us cleanly rollback if the gate
fails.

A plan in the queue is a contract: the human already decided it is
ready to ship. **Implement it fully.** Do not abandon on size judgment,
do not split it mid-iteration, do not stop because "this looks like a
lot," even if it spans hundreds of lines across many files. There is
no wall-clock budget. An LLM iteration is bounded by context window
and output tokens, **not minutes**, and modern models have ample room
for plans an order of magnitude larger than what would fit in a
human-sized "30 minutes."

**Track every file you edit or create in two lists**:
- `MODIFIED_BY_SKILL`: existing files you opened and edited.
- `CREATED_BY_SKILL`: new files you wrote that did not exist before.

Both lists are critical for safe success-commit and failure-rollback in
a dirty tree. If you need to edit a file that's already in `$PRE_DIRTY`
(the user's parallel work), it's a real conflict; your edit will land
on top of theirs and the eventual commit will include both. Note this
in the iteration's commit message body so they can review.

### Sizing: warn, never stop

If, after reading the plan and the surrounding code, you judge the
scope to be unusually large (rough heuristics: >500 lines moved, >10
new files, deep cross-package refactor, or both extensive new code AND
extensive new tests with mocks), state that in one sentence before you
start implementing, then keep going. The warning lets the human see
your read of scope in the log; it does **not** authorize you to stop.

"Feels like a lot," "would take many tool calls," "spans multiple
files," and "the plan bundles three things" are **not** reasons to
abandon. Plans get authored at the size they need to be. If a plan is
genuinely the wrong size, the human will revise it after seeing the
result, not before you've tried.

### The only legitimate failure modes

- **Gate stays red after investigation** (Step 5, 3-strike rule exhausted).
- **Architectural blocker**: implementing the plan as written would
  require a design decision the plan didn't account for. Record the
  specific blocker in the failure commit so the human can revise.
- **Context exhaustion**: the conversation is genuinely approaching
  the context limit and cannot finish safely. Rare; flag explicitly
  as `failed-reason: context-exhausted`.

Hard cap on investigation: **3 strikes per root cause category, max 3
categories** (see mstack-investigate). This gives up to 9 total attempts
for genuinely complex bugs while still preventing infinite loops.

## Step 5: Verification gate (mstack-code-health)

Run the health check script. It discovers tools, runs them, scores each
category 0-10, computes a weighted composite, persists to history, and
returns a structured verdict:

```bash
PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
```

Parse the output; each line is `KEY:VALUE`:

```
VERDICT:PASS
COMPOSITE:9.1
TYPECHECK:10
LINT:8
TEST:10
DEADCODE:7
SHELL:10
DURATION:23
FAILURES:none
```

**Progress:** After parsing the health output, print:
```
[mstack] ├─ Health gate: <COMPOSITE>/10 (<VERDICT>)
```

Act on the VERDICT line:
- **PASS** (composite >= 7.0, no category at 0) → proceed to Step 5b
- **FAIL** (composite < 7.0, or any category at 0) → enter investigation
- **REGRESSED** (composite dropped >= 1.0 from previous) → enter investigation

### On FAIL or REGRESSED: mstack-investigate

Instead of retrying blindly, run structured debugging using
mstack-investigate logic:

1. Read the plan file for context (acceptance criteria, expected files)
2. Collect symptoms from health output (which tools failed, exact errors)
3. **Phase 1**: Root cause investigation: trace code, check changes, search learnings
4. **Phase 2**: Pattern analysis: match against known failure patterns
5. **Phase 3**: Hypothesis testing with mandatory reflection before each attempt:
   ```
   ATTEMPT N/3
   Previous: <what was tried>
   Hypothesis: <specific, testable claim>
   Am I repeating myself: <yes/no>
   ```
6. **Phase 4**: Minimal fix + regression test

**Category-aware strike rule:** 3 strikes per root cause category, max 3
categories (9 total attempts). After all categories exhausted, mark the
plan failed with detailed diagnosis. Do not enter a retry loop.

If investigation succeeds (FIXED): re-run the health check to confirm,
then proceed to Step 5b.

If investigation fails (3 strikes exhausted): Step 7 failure path.

## Step 5b: Verification gate (feature correctness)

After the health gate passes, verify the plan's acceptance criteria are
actually met by executing the checks in the `## Verification` section.

### Parse the Verification section

Read the plan file's `## Verification` section. Extract lines matching:
- `[cmd] <command>`: run the command, assert exit code 0
- `[assert] <command> | <expected>`: run the command, assert stdout contains the expected string
- `[status] <curl command> -> <code>`: run the curl, assert HTTP status matches
- `[browse] <url-or-path> <assertion>`: browser-based check via gstack's /browse skill
- `[manual] <description>`: log as skipped (human review only)

If no executable checks exist (section empty, all `[manual]`, or only
template placeholder `- ...`):
- If the plan has `verification: health-only` in frontmatter: skip this
  step, proceed to Step 5c. Log: "verification: health-only, skipping
  feature checks per architect override."
- Otherwise: this should not happen (plan-doctor blocks plans without
  verification). Treat as a failure; the plan spec is incomplete.
  Set `failed-reason: missing-verification-checks` and go to Step 7b.

### Execute checks

For each executable check (30-second timeout per check):

```bash
mkdir -p "$REPO_ROOT/.mstack/evidence/plan-${PLAN_ID}"
```

**`[cmd]`**: Run the command. Pass if exit code is 0.

**`[assert]`**: Run the command before the `|`. Check if stdout contains
the string after `|` (trimmed). Pass if found.

**`[status]`**: Run the curl command. Extract the HTTP status code. Pass
if it matches the expected code after `→`.

**`[browse]`**: Browser-based check execution via gstack's /browse skill.
Format: `[browse] <url-or-path> <assertion>` where the assertion is a
natural language description of what to verify (e.g.,
`[browse] /settings/billing verify 'Current Plan' heading is visible`).

**[browse] check execution steps:**

1. **Detect gstack installation:** Check if the browse skill is available:
   ```bash
   test -f "${HOME}/.config/skillshare/skills/browse/SKILL.md" || \
   test -f "${HOME}/.claude/skills/gstack/browse/SKILL.md"
   ```

2. **If gstack not installed:** Skip all `[browse]` checks with a warning:
   ```
   Skipped [browse] check: gstack not installed. Install gstack for browser-based verification.
   ```
   Record the check as `SKIPPED` in the evidence directory. `[browse]`
   skips do not count as failures; treat them like `[manual]` checks.

3. **If gstack is installed:** Ensure the dev server is running before
   executing any `[browse]` checks:
   - Read `CLAUDE.md` for the project's start command (e.g., `npm run dev`,
     `pnpm dev`). If not found, check `package.json` for a `"dev"` or
     `"start"` script.
   - If the dev server is not already running, start it in the background.
   - Wait for the server to become ready: poll the health endpoint or
     check the port (retry up to 15s with 1s intervals).
   - If the server fails to start within 15s, skip `[browse]` checks with
     a warning: "Dev server failed to start. Skipping [browse] checks."

4. **For each `[browse]` check:**
   - Parse the check line: extract `<path>` and `<assertion>`.
   - Invoke the `/browse` skill with instructions to navigate to the path
     and verify the assertion (natural language).
   - Pass if the browse skill confirms the assertion is met.
   - Fail if the browse skill reports the assertion is not met or errors.
   - Record the result to `.mstack/evidence/plan-${PLAN_ID}/check-N.txt`.

5. **After all `[browse]` checks complete:** Stop the dev server if this
   step started it (do not stop a server that was already running).

`[browse]` check failures are treated the same as `[cmd]` failures: the
plan enters investigation with the same 3-strike category-aware rule.

For checks that require a running server (including `[status]` and `[cmd]`
checks that hit endpoints): read CLAUDE.md for the start command, start
it in the background, wait for readiness (retry the health endpoint up
to 10s), run checks, then stop it.

Record each result to `.mstack/evidence/plan-${PLAN_ID}/check-N.txt`:
```
PASS | [cmd] npm run test:e2e -- --grep rate-limit | exit 0
```
or:
```
FAIL | [status] curl -sw '%{http_code}' localhost:3000/api/users → 500 (expected 200)
OUTPUT: {"error":"not_initialized"}
```

### Write summary

After all checks complete, write `.mstack/evidence/plan-${PLAN_ID}/summary.md`:

```markdown
# Verification: plan-${PLAN_ID}

N/M checks passed

| # | Type   | Check                     | Result |
|---|--------|---------------------------|--------|
| 1 | cmd    | npm run test:e2e ...      | PASS   |
| 2 | assert | curl ... \| grep ok       | PASS   |
| 3 | manual | Check login page renders  | SKIPPED |

Failed output:
  (only if any failures; include the first 500 chars of stdout/stderr)
```

### Act on results

- **All executable checks PASS** → proceed to Step 5c
- **Any check FAIL** → enter investigation (same 3-strike rule as Step 5).
  The investigation context includes which check failed and its output.
  After 3 strikes: Step 7 failure path with
  `failed-reason: "verification: <check description>"`
- **All checks skipped/manual** → proceed to Step 5c (no evidence written)

### Update qa: field

Track what verification level was achieved for the commit trailer:
- Health gate only (no executable checks) → `qa: automated`
- Health gate + verification checks passed → `qa: automated,verified`

## Step 5c: Cleanup sweep

After the verification gate passes, run a targeted cleanup sweep on only
the files created or modified by the current plan. This catches artifacts
that slip through during implementation before they reach code review.

### Get changed files

Collect the list of files this plan touched:

```bash
# Files changed since the recovery point (includes claim commit + uncommitted work)
git diff --name-only ${RECOVERY} HEAD
git diff --name-only HEAD
```

Combine both lists (deduplicated). This is the scope of the sweep; never
check files outside this set.

### Check for artifacts

For each changed file, scan for:

1. **Unused imports**: `import`/`require` statements where the imported
   name does not appear elsewhere in the file. Use grep-level heuristics,
   not AST analysis.

2. **Dead functions**: functions or classes defined in the file that are
   not called anywhere within the changed files or imported by other
   files in the diff.

3. **Debug artifacts**: `console.log`, `debugger` statements, `TODO`,
   `FIXME`, `HACK` comments that were added during implementation (not
   pre-existing). Compare against the recovery point to distinguish new
   from existing:
   ```bash
   git diff ${RECOVERY} -- <file> | grep '^+' | grep -E 'console\.log|debugger|TODO|FIXME|HACK'
   ```

4. **Orphan files**: new files (present in CREATED list) that are not
   imported or referenced by any other file in the project:
   ```bash
   grep -rl "<filename>" . --include='*.ts' --include='*.js' --include='*.md' | grep -v <the file itself>
   ```

### Act on findings

- **Issues found**: fix them in the working tree, then re-run the health
  gate to confirm no regressions:
  ```bash
  PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
  ```
  If the health gate passes after cleanup, proceed to Step 6.
  If it fails, revert the cleanup fixes and proceed to Step 6 with the
  original passing implementation.

- **No issues**: proceed directly to Step 6.

### Progress output

```
[mstack] ├─ Cleanup: removed 2 unused imports, 1 debug statement
```
or:
```
[mstack] ├─ Cleanup: nothing to clean
```

## Step 6: Code review (mstack-code-review)

After the cleanup sweep (Step 5c) completes, run a structured code review
using mstack-code-review logic.

### Discovery: external models

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
command -v gemini >/dev/null 2>&1 && echo "GEMINI: available" || echo "GEMINI: unavailable"
```

Read `.mstack/config.json` `review.provider` for preference. Pick the
best available external model for one reviewer (codex > gemini > claude-only).

### Run review (configurable depth)

Check the plan's `review` frontmatter field:
- **Standard** (default, or `review` field absent): 1 unified reviewer
  covering correctness, conventions, and simplicity in one pass. Route
  through external model if available.
- **Thorough** (`review: thorough`): 3 blind review agents (correctness,
  conventions, simplicity), each scoring independently. Route one through
  external model for generator/judge separation.

### Filter and act

1. Discard findings below confidence 7
2. Deduplicate (same file:line from multiple reviewers)
3. **Critical/High**: fix immediately
4. **Medium**: fix if trivial (< 2 edits), otherwise note in commit message

After applying fixes, re-run the health gate (Step 5) to confirm nothing
broke. If the gate fails, revert the review-inspired changes and proceed
with the original passing implementation.

One review cycle only. Do not re-run reviewers after applying feedback.

**Progress:** After the review completes and fixes are applied, print:
```
[mstack] ├─ Code review: <N> findings, <N> fixed
```
where the first N is total findings above confidence 7, and the second N
is findings that were actually fixed. If no findings: "0 findings, 0 fixed".

### Write review artifact

```bash
mkdir -p "$REPO_ROOT/.mstack/reviews"
```

Write to `$REPO_ROOT/.mstack/reviews/plan-${PLAN_ID}.json` with findings
count, providers used, and fixes applied. See mstack-code-review for schema.

## Step 7: Commit outcome

Use the MODIFIED and CREATED lists from the subagent's
`---MSTACK-RESULT---` block. These are the files to stage.

### 7a. On success

1. Update `$NEXT` frontmatter:
   - `status: pending` → `status: done`
   - Add `completed: <YYYY-MM-DD>`
   - Add `reviewed: false` (the human hasn't seen this yet)
   - Add `qa: automated` (the verification gate passed: typecheck/lint/tests)

2. Commit by explicit file list (never `git add .`):
   ```bash
   git add <MODIFIED + CREATED from subagent result, including the plan>
   git commit -m "<conventional message>"
   ```

   Conventional message shape:
   - Type: `fix` for bugs, `feat` for additions, `chore` for cleanup.
   - Scope: most-affected app/package (e.g., `lookbook-api`, `web`).
   - Subject: short imperative summary of what changed.
   - Body: 1–3 sentences on the why.
   - Trailer: `Refs: docs/plans/<file>` so the plan link is grep-able
     from `git log`.

   Example:
   ```
   fix(lookbook-api): only mark scraped items 'ready' when usable

   When the scraper returned 2xx with an empty payload, items landed in
   the public feed indistinguishable from real listings. Adds an
   exported isUsableScrapeResult() predicate gating the full UPDATE.

   Refs: docs/plans/34-scraper-empty-payload-ready-bug.md
   ```

3. **Progress: committed milestone.** After the commit succeeds, print:

   ```
   [mstack] └─ Committed: <commit message first line>
   ```

   This is the final milestone for a successful plan (hence `└─`).

4. **Tag the completion:**
   ```bash
   git tag "mstack/plan-${PLAN_ID}-done"
   ```

5. **Do not push.** The user pushes when ready.

### 7b. On failure (gate red after investigation, architectural blocker, or context exhaustion)

See Step 4 "The only legitimate failure modes." "Scope feels big" is
**not** on the list.

1. **Surgical revert**: the subagent already reverted on failure
   (see Step 3d prompt, STEP C). Verify the working tree is clean
   of skill changes by checking that MODIFIED and CREATED files from
   the result block are back to HEAD state. If any remain dirty and
   are not in PRE_DIRTY, revert them:
   ```bash
   for f in <MODIFIED from result minus PRE_DIRTY>; do
     git checkout HEAD -- "$f"
   done
   for f in <CREATED from result>; do
     rm -f "$f"
   done
   ```

   If a file is in BOTH MODIFIED AND `$PRE_DIRTY` (rare;
   means we edited a file the user was already editing): leave it
   alone. Our changes ride along with theirs into their next commit;
   they'll resolve manually if needed. Note this in the failure-commit
   message body.

2. Update `$NEXT` frontmatter: `status: in-progress` → `status: failed`, add
   `failed-reason: <short, e.g. "gate red: TypeScript errors in X">` and
   `failed-at: <YYYY-MM-DD>`.

3. Commit only the plan file:
   ```bash
   git add "$NEXT"
   git commit -m "chore(plan ${PLAN_ID}): failed (<short reason>)"
   ```

4. **Progress: failure milestone.** If the subagent did not already print
   a `[mstack] └─ FAILED` line, print it now:

   ```
   [mstack] └─ FAILED: <one-line reason from failed-reason>
   ```

5. **Do not push.**

## Step 7c: Learnings: extract

After either success (7a) or failure (7b), extract 0-2 learnings from this
iteration. Only extract patterns that are:
- **Non-obvious**: can't be inferred from CLAUDE.md or file names
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

### If the backlog is empty (Step 2 found nothing)

Run the **final validation pass**, then the **simplify pass** and
**completion notification**, then print "Backlog clear." and exit.
`/goal` will see this and stop.

#### Final validation pass

After all plans have been executed (or failed/skipped) and before the
simplify pass, run a full-codebase health gate to catch cross-plan
regressions. This uses the same health-check.sh but without a PLAN_ID,
so it checks everything rather than scoping to one plan's changes.

Print:
```
[mstack] Final validation: running full test suite...
```

Run:
```bash
bash "$SKILL_DIR/scripts/health-check.sh" run
```

(Note: no PLAN_ID env var set, so the script runs against the full codebase.)

Parse the VERDICT and COMPOSITE. Print the result:

- On PASS:
  ```
  [mstack] Final validation: <COMPOSITE>/10 (PASS)
  ```

- On FAIL:
  ```
  [mstack] Final validation: FAILED (<which categories failed with their scores>)
  ```

  If the final validation fails, identify which specific tests/checks
  failed from the health output. Then use `git blame` on the failing
  lines to attribute the regression to a specific plan commit:

  ```bash
  git blame <failing file> | grep -E "<plan commit hashes>"
  ```

  Cross-reference plan commit hashes (from `git log --oneline` looking
  for `chore(plan N)` or `feat(...)` commits from this session) to
  identify the likely source plan. Print:

  ```
  [mstack] WARNING: Cross-plan regression detected.
  [mstack]   <category> failures: <details>
  [mstack]   likely source: plan <id> (commit <hash>) modified <file>
  [mstack]   Review the failures above before pushing.
  ```

  If `git blame` cannot isolate the regression to a single plan, report
  the failures without attribution.

  **Final validation failure does NOT mark any plan as failed.** Each
  plan passed its individual health gate. The regression is a cross-plan
  interaction that the user must review. Do not auto-fix.

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

`/goal` will start a new turn, CLAUDE.md routing will invoke mstack-run
again, and the next plan gets picked up.

### If a bail check failed (Step 1)

Print the bail reason and exit. `/goal` will see the error and stop.

## Recovery from a failed iteration's commit

If a `chore(plan N): failed (...)` commit lands but the user wants to
re-attempt, they edit the plan frontmatter back to `status: pending` and
re-run `/mstack-run`. The skill is idempotent on plan state; only
the picker's `status: pending` filter matters.
