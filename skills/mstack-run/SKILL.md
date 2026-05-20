---
name: mstack-run
description: |
  Pick the next unblocked plan from `docs/plans/` (or `plans/`), implement
  it directly on the default branch, run the project's verification gate
  (typecheck/lint/test), and commit. Designed for a solo-dev workflow that
  lives on `main` — no feature branches, no PRs, no automatic push. The
  user reviews `git log -p` and pushes when ready.

  Intended to run autonomously under `/loop /mstack-run` (self-paced)
  so a backlog of plan files can be worked through unattended.
disable-model-invocation: true
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
one plan, commit it, and exit. Do not chain into a second plan — `/loop`
handles that.

## Hard rules (never violate)

- **Never push to remote.** The user pushes manually after reviewing.
- **Never edit `db/migrations/**`** unless the picked plan's frontmatter
  has `allows-migrations: true`. Migrations run sequentially by hand.
- **Never bypass the verification gate.** If checks fail after
  investigation (3-strike rule), abandon the iteration and rollback
  (Step 7) — never commit broken code to `main`.
- **Never `--no-verify`, `--no-gpg-sign`, or any commit/push escape hatch.**
- **Never amend or rebase** prior commits. Each iteration is a single
  forward commit.
- **Never delete a plan file.** Set `status: failed` instead.

## Step 1 — Startup

Run bail checks and load configuration. **Do not schedule another
iteration on bail** — the loop ends here.

### Auto-init

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

### Bail checks

```bash
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "BAIL: not a git repo"; exit 1; }

# Detect stale worktrees — .git is a file (not a dir) in worktrees
REPO_ROOT=$(git rev-parse --show-toplevel)
if [ -f "$REPO_ROOT/.git" ]; then
  WORKTREE_BRANCH=$(git branch --show-current)
  echo "BAIL: in a worktree ($WORKTREE_BRANCH) left over from a previous session."
  echo "Run: ExitWorktree { action: 'remove' } — or start a new conversation from the main repo directory."
  exit 1
fi

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
[ "$(git branch --show-current)" = "$DEFAULT_BRANCH" ] || { echo "BAIL: not on $DEFAULT_BRANCH"; exit 1; }

[ -d docs/plans ] || [ -d plans ] || { echo "no plans dir — nothing to do"; exit 0; }
```

A dirty working tree is **allowed** — this skill coexists with parallel
user edits. The success/rollback paths in Step 7 use surgical add /
revert by explicit file list, never `git add .` or `git reset --hard`.

If anything fails, tell the user what went wrong in one sentence and stop.

### Load config

Read `.mstack/config.json` if it exists (see mstack-config for schema).
Extract settings that affect this iteration:

```bash
CONFIG_FILE="$REPO_ROOT/.mstack/config.json"
[ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "NO_CONFIG"
```

Note the `autonomy` default, `health.commands`, `health.weights`,
`review.provider`, `ignored_paths`, and `commit` settings. Any setting
not present falls back to the built-in defaults documented in mstack-config.

### Crash recovery from checkpoint

Read the latest checkpoint if it exists:

```bash
CHECKPOINT_FILE="$REPO_ROOT/.mstack/checkpoints/latest.json"
[ -f "$CHECKPOINT_FILE" ] && cat "$CHECKPOINT_FILE" || echo "NO_CHECKPOINT"
```

If a checkpoint exists:
- Carry forward `user_context` entries into your working memory. Treat them
  as constraints during implementation.
- Check if `plan_status` is `"in-progress"` — that means the previous session
  crashed mid-plan. Log: "Previous session crashed during plan ${plan_id}.
  Plan remains in-progress — pick-next will skip to the next plan."
- Read `counters` for continuity (plans completed so far, health trend).

### Prune stale checkpoints

```bash
find "$REPO_ROOT/.mstack/checkpoints" -name "*.json" ! -name "latest.json" -mtime +7 -delete 2>/dev/null || true
```

## Step 2 — Pick the next plan

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
NEXT=$(bash "$SKILL_DIR/scripts/pick-next.sh")
```

If `$NEXT` is empty: print "Backlog clear." and exit. Do not call
`ScheduleWakeup`.

Immediately claim the plan to prevent parallel sessions from picking it:

1. Update `status: pending` → `status: in-progress` in the plan's frontmatter.
2. Commit the claim:
   ```bash
   git add "$NEXT"
   git commit -m "chore(plan ${PLAN_ID}): claim — in progress"
   ```

This must happen before any other work. If the plan later fails the
readiness gate or implementation, the rollback/failure steps will handle
resetting the status.

## Step 3 — Snapshot pre-existing edits and read context

```bash
RECOVERY=$(git rev-parse HEAD)
echo "Recovery point: $RECOVERY"

# Files the user already had modified or untracked before this iteration.
# We won't touch them in our success commit OR our failure rollback —
# they belong to the user's in-flight work.
PRE_DIRTY=$(git status --porcelain | awk '{print $2}' | sort -u)
echo "Pre-existing dirty files (off-limits to skill rollback):"
echo "$PRE_DIRTY"
```

Keep `$PRE_DIRTY` in mind throughout. If you need to edit a file that's
in this list, that's a real conflict — flag it in the iteration's commit
message and let the user reconcile.

Read `CLAUDE.md` (root + any nearer to the plan's scope). Note:
- Test/typecheck/lint commands (default: `pnpm test`, `pnpm -r typecheck`,
  `pnpm -r lint`).
- Any "Phase 0" / migration / RLS rules that affect the plan.

Read `$NEXT` end-to-end. Note its `id`, `title`, `blocked-by`,
`allows-migrations`, and the Implementation section.

## Step 3b — Plan readiness gate

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
   git commit -m "chore(plan ${PLAN_ID}): blocked — incomplete spec"
   ```
3. Print:
   ```
   plan ${PLAN_ID}: blocked — incomplete spec. Run /mstack-plan-doctor ${PLAN_ID} to fix.
   ```
4. Continue to Step 8 (schedule next iteration) — skip to the next plan in
   the backlog rather than stopping the loop entirely.

Do NOT attempt to implement a plan with placeholder content. The human
must fill in the spec first.

## Step 3c — Learnings: prune and apply

Set up the learnings store and consult prior knowledge:

```bash
mkdir -p "$REPO_ROOT/.mstack"
grep -q "^\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".mstack/" >> "$REPO_ROOT/.gitignore"
```

**Prune:** Read `$REPO_ROOT/.mstack/learnings.jsonl` (and `~/.mstack/learnings.jsonl`
if it exists). For each entry, verify that files in `refs` still exist. Remove
entries where >50% of refs are gone. Remove entries with `confidence` <= 3 that
haven't been verified in 30+ days. Remove duplicates (same `key`, keep higher
confidence). Update `last_verified` on survivors.

**Apply:** Match learnings against this plan's `**Files expected to change:**`
list and its title/requirements keywords. Print matched learnings as
implementation guidance:

```
Relevant learnings for plan ${PLAN_ID}:
  [9] api-handlers-need-auth — All route handlers in src/api/ must wrap with authMiddleware
  [7] error-responses-use-problem-json — Error responses follow RFC 7807 format
```

Treat these as constraints during implementation. If a learning contradicts
the plan's explicit instructions, the plan wins (it was written by the human).

## Step 4 — Implement (no commits yet)

Make the changes required by the plan. **Do not commit during
implementation** — uncommitted edits let us cleanly rollback if the gate
fails.

A plan in the queue is a contract: the human already decided it is
ready to ship. **Implement it fully.** Do not abandon on size judgment,
do not split it mid-iteration, do not stop because "this looks like a
lot" — even if it spans hundreds of lines across many files. There is
no wall-clock budget. An LLM iteration is bounded by context window
and output tokens, **not minutes**, and modern models have ample room
for plans an order of magnitude larger than what would fit in a
human-sized "30 minutes."

**Track every file you edit or create in two lists**:
- `MODIFIED_BY_SKILL` — existing files you opened and edited.
- `CREATED_BY_SKILL` — new files you wrote that did not exist before.

Both lists are critical for safe success-commit and failure-rollback in
a dirty tree. If you need to edit a file that's already in `$PRE_DIRTY`
(the user's parallel work), it's a real conflict — your edit will land
on top of theirs and the eventual commit will include both. Note this
in the iteration's commit message body so they can review.

### Sizing — warn, never stop

If, after reading the plan and the surrounding code, you judge the
scope to be unusually large (rough heuristics: >500 lines moved, >10
new files, deep cross-package refactor, or both extensive new code AND
extensive new tests with mocks), state that in one sentence before you
start implementing — then keep going. The warning lets the human see
your read of scope in the log; it does **not** authorize you to stop.

"Feels like a lot," "would take many tool calls," "spans multiple
files," and "the plan bundles three things" are **not** reasons to
abandon. Plans get authored at the size they need to be. If a plan is
genuinely the wrong size, the human will revise it after seeing the
result — not before you've tried.

### The only legitimate failure modes

- **Gate stays red after investigation** (Step 5 — 3-strike rule exhausted).
- **Architectural blocker** — implementing the plan as written would
  require a design decision the plan didn't account for. Record the
  specific blocker in the failure commit so the human can revise.
- **Context exhaustion** — the conversation is genuinely approaching
  the context limit and cannot finish safely. Rare; flag explicitly
  as `failed-reason: context-exhausted`.

Hard cap on investigation: **3 strikes** (see mstack-investigate).

## Step 5 — Verification gate (mstack-code-health)

Run the health check using mstack-code-health logic. This replaces the
inline `pnpm typecheck && lint && test` with structured scoring.

1. **Discover tools** from `.mstack/config.json` `health.commands`, then
   CLAUDE.md `## Health Stack`, then auto-detect. Use configured
   `health.weights` if present, otherwise defaults (typecheck 25%,
   lint 20%, test 30%, deadcode 15%, shell 10%).

2. **Run each tool**, score 0-10 per category, compute weighted composite.

3. **Compare** against previous `.mstack/health-history.jsonl` entry.

4. **Persist** one JSONL line to `.mstack/health-history.jsonl`:
   ```json
   {"ts":"<ISO>","branch":"main","plan_id":"<ID>","score":9.1,"typecheck":10,"lint":8,"test":10,"deadcode":7,"shell":10,"duration_s":23}
   ```

5. **Determine verdict:**
   - **PASS** (composite >= 7.0, no category at 0) → proceed to Step 6
   - **FAIL** (composite < 7.0, or any category at 0) → enter investigation
   - **REGRESSED** (composite dropped >= 1.0 or any category dropped >= 3) → enter investigation

### On FAIL or REGRESSED — mstack-investigate

Instead of retrying blindly, run structured debugging using
mstack-investigate logic:

1. Read the plan file for context (acceptance criteria, expected files)
2. Collect symptoms from health output (which tools failed, exact errors)
3. **Phase 1**: Root cause investigation — trace code, check changes, search learnings
4. **Phase 2**: Pattern analysis — match against known failure patterns
5. **Phase 3**: Hypothesis testing with mandatory reflection before each attempt:
   ```
   ATTEMPT N/3
   Previous: <what was tried>
   Hypothesis: <specific, testable claim>
   Am I repeating myself: <yes/no>
   ```
6. **Phase 4**: Minimal fix + regression test

**Hard 3-strike rule:** after 3 failed hypotheses, mark the plan failed
with detailed diagnosis. Do not enter a retry loop.

If investigation succeeds (FIXED): re-run the health check to confirm,
then proceed to Step 6.

If investigation fails (3 strikes exhausted): Step 7 failure path.

## Step 6 — Code review (mstack-code-review)

After the health gate passes, run a structured code review using
mstack-code-review logic.

### Autonomy check

Read the plan's `autonomy` frontmatter field. If not set, use the default
from `.mstack/config.json` `autonomy`, or `"full"` if no config.

- **`supervised`**: STOP here. Print the uncommitted diff and wait for the
  user to inspect before proceeding. Resume when the user says to continue.
- **`checkpoint`** or **`full`**: continue automatically.

### Discovery — external models

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
command -v gemini >/dev/null 2>&1 && echo "GEMINI: available" || echo "GEMINI: unavailable"
```

Read `.mstack/config.json` `review.provider` for preference. Pick the
best available external model for one reviewer (codex > gemini > claude-only).

### Spawn 3 blind review agents

Each agent receives the uncommitted diff and a narrow brief. They score
findings 1-10 independently. They do not see each other's output.

1. **Correctness**: logic errors, missing edge cases, acceptance criteria
2. **Conventions**: naming, imports, error handling, CLAUDE.md rules
3. **Simplicity**: over-engineering, duplication, unnecessary abstractions

Route one reviewer through the best available external model (generator/judge
separation). If no external model is available, all three run as Claude agents.

### Filter and act

1. Discard findings below confidence 7
2. Deduplicate (same file:line from multiple reviewers)
3. **Critical/High**: fix immediately
4. **Medium**: fix if trivial (< 2 edits), otherwise note in commit message

After applying fixes, re-run the health gate (Step 5) to confirm nothing
broke. If the gate fails, revert the review-inspired changes and proceed
with the original passing implementation.

One review cycle only. Do not re-run reviewers after applying feedback.

### Write review artifact

```bash
mkdir -p "$REPO_ROOT/.mstack/reviews"
```

Write to `$REPO_ROOT/.mstack/reviews/plan-${PLAN_ID}.json` with findings
count, providers used, and fixes applied. See mstack-code-review for schema.

## Step 7 — Commit outcome

### 7a. On success

1. Update `$NEXT` frontmatter:
   - `status: pending` → `status: done`
   - Add `completed: <YYYY-MM-DD>`
   - Add `reviewed: false` (the human hasn't seen this yet)
   - Add `qa: automated` (the verification gate passed — typecheck/lint/tests)

2. Commit by explicit file list — never `git add .`:
   ```bash
   git add <each file you touched, including the plan>
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

3. **Tag the completion:**
   ```bash
   git tag "mstack/plan-${PLAN_ID}-done"
   ```

4. **Autonomy checkpoint gate.** If the plan's `autonomy` is `checkpoint`:
   STOP here. Print a summary of what was committed and wait for user
   approval before proceeding to the next plan. Resume when the user
   says to continue.

5. **Do not push.** The user pushes when ready.

### 7b. On failure (gate red after investigation, architectural blocker, or context exhaustion)

See Step 4 "The only legitimate failure modes" — "scope feels big" is
**not** on the list.

1. **Surgical revert** — never `git reset --hard`, that would destroy
   the user's parallel work. Use the lists tracked in Step 4:
   ```bash
   # Revert files we modified back to HEAD content. Do NOT pass any
   # path that's in $PRE_DIRTY — those belong to the user.
   for f in <MODIFIED_BY_SKILL minus $PRE_DIRTY>; do
     git checkout HEAD -- "$f"
   done

   # Delete files we created. Each one should not exist at HEAD —
   # so this is safe.
   for f in <CREATED_BY_SKILL>; do
     rm -f "$f"
   done
   ```

   If a file is in BOTH `MODIFIED_BY_SKILL` AND `$PRE_DIRTY` (rare —
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

4. **Do not push.**

## Step 7c — Learnings: extract

After either success (7a) or failure (7b), extract 0-2 learnings from this
iteration. Only extract patterns that are:
- **Non-obvious** — can't be inferred from CLAUDE.md or file names
- **Reusable** — would help a future plan touching the same area
- **Concrete** — names specific files, patterns, or constraints

**On success**, look for:
- Architectural patterns ("services in this project always go through the queue")
- Conventions the gate enforced ("imports must use .js extension")
- Dependencies discovered ("module X requires Y to be initialized first")

**On failure**, look for:
- Pitfalls ("the ORM doesn't support X, don't try it")
- Environmental constraints ("this test suite needs the DB running")
- Architectural blockers ("can't do X without first refactoring Y")

For each learning, write a JSON line to `$REPO_ROOT/.mstack/learnings.jsonl`:

```json
{"key":"<slug>","insight":"<one sentence>","type":"pattern|pitfall|convention|dependency","evidence":"plan-${PLAN_ID}","confidence":7,"refs":["<file paths>"],"created":"<YYYY-MM-DD>","last_verified":"<YYYY-MM-DD>"}
```

Before appending, check if a learning with the same `key` exists:
- If yes and new evidence reinforces it: bump confidence (+1, max 10), update
  `last_verified`.
- If yes and contradicts: replace (newer evidence wins).
- If no: append.

If nothing worth extracting: skip silently.

## Step 7d — Write checkpoint (mstack-checkpoint)

After every plan completion (success or failure), write checkpoint state
using mstack-checkpoint logic. This enables crash recovery for the next
session.

```bash
mkdir -p "$REPO_ROOT/.mstack/checkpoints"
```

Write to `$REPO_ROOT/.mstack/checkpoints/latest.json` (and a timestamped
copy). The checkpoint carries **facts, not reasoning**:

- **attempts**: append this plan's outcome with observable errors
- **user_context**: preserve from previous checkpoint (accumulates)
- **counters**: update plans_completed/failed/remaining, health trend,
  investigate strikes used

See mstack-checkpoint for the full schema. Key principle: a fresh session
gets evidence and forms its own conclusions. Never write interpretations
or hypotheses into checkpoint data.

## Step 8 — Schedule next iteration (only if invoked via /loop)

If this turn was fired by `/loop /mstack-run` (dynamic mode), call
`ScheduleWakeup` with:
- `prompt: "/mstack-run"`
- `delaySeconds: 60`
- `reason: "next backlog plan"`

**Skip `ScheduleWakeup`** (ending the loop) when:
- Backlog clear (Step 2 found nothing).
- Bail check failed (Step 1).
- A fatal/unexpected error happened that shouldn't repeat blindly.
- You've done 5 iterations in this loop run (track via
  `$REPO_ROOT/.mstack-run.count`; reset if older than 1 hour).
  Ensure `.mstack-*` is in the repo's `.gitignore` — add it if missing.

If invoked manually (no `/loop` parent), do not schedule.

### Simplify pass

When the loop is ending (backlog clear OR 5-iteration cap), run
`/mstack-simplify-code branch` to simplify all changes made during this
session in one pass. This catches cross-plan reuse opportunities and
consistency issues that per-plan analysis would miss.

Run the simplify logic inline (same as the skill's Steps 1-7, scoped to
`git diff $(git merge-base $DEFAULT_BRANCH HEAD)..HEAD`). If there are no
uncommitted simplifications possible, skip. If simplifications are applied
and the gate passes, commit them:

```bash
git add <simplified files>
git commit -m "chore: simplify code from plan session

Post-loop polish: reuse consolidation, clarity fixes, convention alignment.
"
```

### Completion notification

After the simplify pass, if a notification MCP tool is configured in the
allowed-tools above, send a completion message:

```
"mstack-run: backlog clear (or 5-iteration cap reached). N plans done this run. Check git log --oneline -N. Run /mstack-changelog when ready."
```

If no notification tool is configured or it errors, silently skip —
notification is best-effort, never a failure reason.

## End of iteration

End your reply with one terse line: `plan ${PLAN_ID}: <done|failed:reason>`.

The user will read `git log --oneline -5` and `git log -p HEAD` in the
morning to triage and decide whether to push.

## Recovery from a failed iteration's commit

If a `chore(plan N): failed (...)` commit lands but the user wants to
re-attempt, they edit the plan frontmatter back to `status: pending` and
re-run `/mstack-run`. The skill is idempotent on plan state — only
the picker's `status: pending` filter matters.
