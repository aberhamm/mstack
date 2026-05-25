---
name: mstack-run
description: |
  Pick the next unblocked plan from `docs/plans/` (or `plans/`), implement
  it directly on the default branch, run the project's verification gate
  (typecheck/lint/test), and commit. Designed for a solo-dev workflow that
  lives on `main` — no feature branches, no PRs, no automatic push. The
  user reviews `git log -p` and pushes when ready.

  Recommended driver: `/goal all pending mstack plans are done or failed`
  which keeps working autonomously until the backlog is clear. Also works
  as a single manual invocation for one plan at a time.
disable-model-invocation: true
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
one plan, commit it, and exit. Do not chain into a second plan — `/goal`
handles continuation by evaluating whether the backlog is clear.

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

Read configuration using the config script:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
bash "$SKILL_DIR/scripts/config.sh" show
```

Note the `autonomy` default, `health.commands`, `health.weights`,
`review.provider`, `ignored_paths`, and `commit` settings. Use
`bash "$SKILL_DIR/scripts/config.sh" get <dotpath>` for individual values
(e.g., `get autonomy`, `get health.weights.test`). The script falls back
to built-in defaults when no config exists.

### Crash recovery from checkpoint

Read the latest checkpoint using the checkpoint script:

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" read
```

Exit code 2 means no checkpoint exists. If a checkpoint exists:
- Carry forward `user_context` entries into your working memory. Treat them
  as constraints during implementation.
- Check if `plan_status` is `"in-progress"` — that means the previous session
  crashed mid-plan. Log: "Previous session crashed during plan ${plan_id}.
  Plan remains in-progress — pick-next will skip to the next plan."
- Read `counters` for continuity (plans completed so far, health trend).

### Prune stale checkpoints

```bash
bash "$SKILL_DIR/scripts/checkpoint.sh" prune
```

## Step 2 — Pick the next plan

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
NEXT=$(bash "$SKILL_DIR/scripts/pick-next.sh")
```

The picker selects the lowest-priority pending plan whose dependencies are
met (lowest `priority:` first, then lowest `id:` as tiebreaker; plans
without `priority:` default to their `id:`).

If `$NEXT` is empty: run the simplify pass and completion notification
(Step 8), print "Backlog clear." and exit. The `/goal` evaluator will
see this and stop.

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
  [9] api-handlers-need-auth — All route handlers in src/api/ must wrap with authMiddleware
  [7] error-responses-use-problem-json — Error responses follow RFC 7807 format
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
Related stash: "<title>" — review with /mstack-stash resume N
```

This is informational only — do not block on it or require user action.
The plan proceeds regardless. The user can review the stash later.

## Step 3d — Delegate to implementation agent

Steps 4-6 are noisy (many file reads/edits, health runs, review agents).
Run them inside a **single Agent call** so the parent context stays lean
across multi-plan loops. The parent sees only the structured result.

Construct the Agent prompt from everything gathered in Steps 1-3c. The
prompt must be self-contained — the subagent has no prior context.

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

HARD RULES
- Never commit. Leave all changes uncommitted.
- Never push. Never --no-verify. Never amend.
- Never edit db/migrations/** unless the plan has allows-migrations: true.
- Track every file you touch in two lists: MODIFIED and CREATED.
  Print them in your final output.

STEP A — Read and gate
Read ${NEXT} end-to-end. Read CLAUDE.md for project conventions.
Verify the plan is fully specified (real acceptance criteria, real file
paths, 2+ task steps). If still template placeholders:
  1. Set status: blocked, add needs-review: eng
  2. Print RESULT:BLOCKED and stop.

STEP B — Implement
Implement the plan fully. Do not abandon on size. Do not split.
The only legitimate failures: gate red after 3 strikes, architectural
blocker the plan didn't account for, or context exhaustion.

STEP C — Health check
Run: PLAN_ID="${PLAN_ID}" bash "${SKILL_DIR}/scripts/health-check.sh" run
Parse the VERDICT line.
- PASS → continue to Step C2.
- FAIL or REGRESSED → investigate (3-strike max per mstack-investigate).
  If 3 strikes exhausted, revert your changes surgically:
    git checkout HEAD -- <MODIFIED minus PRE_DIRTY>
    rm -f <CREATED>
  Then print RESULT:FAIL with the reason and stop.

STEP C2 — Verification gate
Read the plan's ## Verification section. Parse executable checks:
  [cmd] <command> — run, assert exit 0
  [assert] <command> | <expected> — run, assert stdout contains expected
  [status] <curl> → <code> — run, assert HTTP status matches
  [manual] — skip (log as "skipped: human review")
If no executable checks exist: skip to Step D.
For each check (30s timeout):
  - Run it, record pass/fail + output to .mstack/evidence/plan-${PLAN_ID}/
  - If a check needs a running server, start it first (read CLAUDE.md for
    the start command), run checks, then stop it.
If ALL pass → write summary.md to evidence dir, continue to Step D.
If ANY fail → investigate (3-strike, same as health gate). After 3
  strikes, revert and print RESULT:FAIL.

STEP D — Code review
Check autonomy config. If "supervised": print the diff and stop (the
parent will wait for user approval — but inside the agent, just return
RESULT:NEEDS_REVIEW).

Spawn 3 blind review agents (correctness, conventions, simplicity).
Discard findings below confidence 7. Fix critical/high findings.
Re-run health check after fixes — if it fails, revert the review
fixes and keep the original passing implementation.
Write review artifact to .mstack/reviews/plan-${PLAN_ID}.json.

FINAL OUTPUT — print exactly this block at the end:
---MSTACK-RESULT---
STATUS: pass | fail | blocked
PLAN_ID: ${PLAN_ID}
MODIFIED: file1.ts, file2.ts
CREATED: file3.ts
HEALTH_VERDICT: PASS
HEALTH_COMPOSITE: 9.1
VERIFICATION: pass | skip | fail
VERIFICATION_CHECKS: 3/3 passed (or "skipped — no executable checks")
FAILED_REASON: (only if STATUS is fail)
PRE_DIRTY_CONFLICTS: (files in both MODIFIED and PRE_DIRTY, if any)
---END---
```

### Parse the result

Extract the `---MSTACK-RESULT---` block from the agent's output.

- **`pass`** → proceed to Step 7a. Use MODIFIED + CREATED for the commit.
- **`fail`** → the agent already reverted. Proceed to Step 7b (update
  plan status and commit only the plan file).
- **`blocked`** → the agent already updated the plan. Commit the plan
  file and continue to Step 8 (next plan, don't stop the loop).

If the agent errors or returns no result block, treat as a failure:
revert any uncommitted changes not in PRE_DIRTY, set the plan to
`status: failed` with `failed-reason: agent-error`, and continue.

---

The steps below (4-6) are the **detailed reference** for the subagent's
behavior. They are embedded in the prompt template above in condensed
form. Keep them in sync — the template is the executable version, these
sections are the authoritative specification.

---

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

Run the health check script. It discovers tools, runs them, scores each
category 0-10, computes a weighted composite, persists to history, and
returns a structured verdict:

```bash
PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
```

Parse the output — each line is `KEY:VALUE`:

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

Act on the VERDICT line:
- **PASS** (composite >= 7.0, no category at 0) → proceed to Step 6
- **FAIL** (composite < 7.0, or any category at 0) → enter investigation
- **REGRESSED** (composite dropped >= 1.0 from previous) → enter investigation

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
then proceed to Step 5b.

If investigation fails (3 strikes exhausted): Step 7 failure path.

## Step 5b — Verification gate (feature correctness)

After the health gate passes, verify the plan's acceptance criteria are
actually met by executing the checks in the `## Verification` section.

### Parse the Verification section

Read the plan file's `## Verification` section. Extract lines matching:
- `[cmd] <command>` — run the command, assert exit code 0
- `[assert] <command> | <expected>` — run the command, assert stdout contains the expected string
- `[status] <curl command> → <code>` — run the curl, assert HTTP status matches
- `[manual] <description>` — log as skipped (human review only)

If no executable checks exist (section empty, all `[manual]`, or only
template placeholder `- ...`): skip this step silently, proceed to Step 6.

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

For checks that require a running server: read CLAUDE.md for the start
command, start it in the background, wait for readiness (retry the health
endpoint up to 10s), run checks, then stop it.

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
  (only if any failures — include the first 500 chars of stdout/stderr)
```

### Act on results

- **All executable checks PASS** → proceed to Step 6
- **Any check FAIL** → enter investigation (same 3-strike rule as Step 5).
  The investigation context includes which check failed and its output.
  After 3 strikes: Step 7 failure path with
  `failed-reason: "verification: <check description>"`
- **All checks skipped/manual** → proceed to Step 6 (no evidence written)

### Update qa: field

Track what verification level was achieved for the commit trailer:
- Health gate only (no executable checks) → `qa: automated`
- Health gate + verification checks passed → `qa: automated,verified`

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

Use the MODIFIED and CREATED lists from the subagent's
`---MSTACK-RESULT---` block. These are the files to stage.

### 7a. On success

1. Update `$NEXT` frontmatter:
   - `status: pending` → `status: done`
   - Add `completed: <YYYY-MM-DD>`
   - Add `reviewed: false` (the human hasn't seen this yet)
   - Add `qa: automated` (the verification gate passed — typecheck/lint/tests)

2. Commit by explicit file list — never `git add .`:
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

1. **Surgical revert** — the subagent already reverted on failure
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

   If a file is in BOTH MODIFIED AND `$PRE_DIRTY` (rare —
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

For each learning, write it via the learnings script (handles dedup/merge
automatically — bumps confidence if the key already exists):

```bash
bash "$SKILL_DIR/scripts/learnings.sh" append '{"key":"<slug>","insight":"<one sentence>","type":"<pattern|pitfall|convention|dependency>","evidence":"plan-${PLAN_ID}","confidence":7,"refs":["<file paths>"],"created":"<YYYY-MM-DD>","last_verified":"<YYYY-MM-DD>"}'
```

If nothing worth extracting: skip silently.

## Step 7d — Write checkpoint (mstack-checkpoint)

After every plan completion (success or failure), construct checkpoint JSON
and write it via the checkpoint script. The checkpoint carries **facts, not
reasoning** — see mstack-checkpoint for the full schema.

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

## Step 8 — Signal completion state

After each plan, output a clear signal that the `/goal` evaluator can
read to decide whether to continue.

### Iteration counter

Track iterations in `$REPO_ROOT/.mstack-run.count`. Increment after each
plan. Reset the counter if the file is older than 1 hour (stale from a
previous session). Ensure `.mstack-*` is in `.gitignore`.

Read the iteration cap from config:

```bash
bash "$SKILL_DIR/scripts/config.sh" get loop.max_iterations
```

Default is 5. Set to 0 for unlimited (`mstack-config set loop.max_iterations 0`).

### Termination conditions

The following conditions signal the backlog loop should end. When any
are true, run the **simplify pass** and **completion notification** below,
then end your turn.

- Backlog clear (Step 2 found nothing)
- Bail check failed (Step 1)
- A fatal/unexpected error that shouldn't repeat blindly
- Iteration cap reached (skip this check if cap is 0)

When none are true (more plans remain and cap not hit), end your turn
with just the status line — `/goal` will start a new turn and the
routing rules in CLAUDE.md will invoke `/mstack-run` again.

### Simplify pass (termination only)

When the loop is ending (backlog clear OR iteration cap), run
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

### Completion notification (termination only)

After the simplify pass, if a notification MCP tool is configured in the
allowed-tools above, send a completion message:

```
"mstack-run: backlog clear (or iteration cap reached). N plans done this run. Check git log --oneline -N. Run /mstack-changelog when ready."
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
