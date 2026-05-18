---
name: mstack-work-next-plan
description: |
  Pick the next unblocked plan from `docs/plans/` (or `plans/`), implement
  it directly on the default branch, run the project's verification gate
  (typecheck/lint/test), and commit. Designed for a solo-dev workflow that
  lives on `main` — no feature branches, no PRs, no automatic push. The
  user reviews `git log -p` and pushes when ready.

  Intended to run autonomously under `/loop /mstack-work-next-plan` (self-paced)
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
- **Never bypass the verification gate.** If checks fail after retries,
  abandon the iteration and rollback (Step 7) — never commit broken code
  to `main`.
- **Never `--no-verify`, `--no-gpg-sign`, or any commit/push escape hatch.**
- **Never amend or rebase** prior commits. Each iteration is a single
  forward commit.
- **Never delete a plan file.** Set `status: failed` instead.

## Step 1 — Bail check

Run these and abort the iteration on any failure. **Do not call
`ScheduleWakeup` on bail** — the loop ends here.

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

## Step 2 — Pick the next plan

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-work-next-plan"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-work-next-plan"
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

- **Gate stays red after 2 self-fix attempts** (Step 5).
- **Architectural blocker** — implementing the plan as written would
  require a design decision the plan didn't account for. Record the
  specific blocker in the failure commit so the human can revise.
- **Context exhaustion** — the conversation is genuinely approaching
  the context limit and cannot finish safely. Rare; flag explicitly
  as `failed-reason: context-exhausted`.

Hard cap on self-fix attempts (Step 5 retries): **2**.

## Step 5 — Verification gate

Run the project's checks against the working tree (uncommitted edits
are fine — `tsc`, `eslint`, `vitest` all read the working tree):

```bash
pnpm -r typecheck && pnpm -r lint && pnpm test
```

Use the commands defined in `CLAUDE.md` if they differ.

If green → Step 7 success path.

If red → diagnose, edit further, re-run. Up to 2 attempts. Still red →
Step 7 failure path.

## Step 6 — Multi-perspective review

After the gate passes (Step 5 green), spawn 3 review agents in parallel.
Each has a narrow focus and reviews the uncommitted diff (`git diff`).

### Agent 1: Correctness

> Review this diff against the plan's acceptance criteria. Check:
> - Does the implementation actually satisfy each `- [ ]` criterion?
> - Are there logic errors, off-by-one bugs, or missing edge cases?
> - Are there null/undefined paths that could crash at runtime?
> - Do error paths handle failures gracefully?
>
> Only report issues you're confident about (>80% certainty).
> Format: one line per issue with file:line and severity (critical/high/medium).

### Agent 2: Conventions

> Review this diff against the project's CLAUDE.md and surrounding code patterns. Check:
> - Does it follow the project's naming conventions?
> - Does it use the established error handling patterns?
> - Does it match the import style and file structure of siblings?
> - Are there project-specific rules being violated?
>
> Only report issues you're confident about (>80% certainty).
> Format: one line per issue with file:line and severity (critical/high/medium).

### Agent 3: Simplicity

> Review this diff for unnecessary complexity. Check:
> - Is anything over-engineered for what the plan requires?
> - Is there duplicated logic that an existing utility already handles?
> - Are there unnecessary abstractions or indirection layers?
> - Could any section be simplified without losing functionality?
> - Are comments appropriate? (WHY not WHAT, single-line preferred, multiline only when necessary)
>
> Only report issues you're confident about (>80% certainty).
> Format: one line per issue with file:line and severity (critical/high/medium).

### Collecting and acting on results

After all 3 agents return, merge their findings. For each issue:

- **Critical**: fix it immediately — these are bugs or security issues.
- **High**: fix it — these are real quality problems.
- **Medium**: fix if trivial (< 2 edits), otherwise note it in the commit
  message body as a known improvement opportunity.

After applying fixes, re-run the verification gate (Step 5) to confirm
nothing broke. If the gate fails, revert the review-inspired changes and
proceed with the original passing implementation.

This counts as ONE review cycle. Do not re-run the review agents after
applying their feedback.

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

3. **Do not push.** The user pushes when ready.

### 7b. On failure (gate red after retries, architectural blocker, or context exhaustion)

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

## Step 8 — Schedule next iteration (only if invoked via /loop)

If this turn was fired by `/loop /mstack-work-next-plan` (dynamic mode), call
`ScheduleWakeup` with:
- `prompt: "/mstack-work-next-plan"`
- `delaySeconds: 60`
- `reason: "next backlog plan"`

**Skip `ScheduleWakeup`** (ending the loop) when:
- Backlog clear (Step 2 found nothing).
- Bail check failed (Step 1).
- A fatal/unexpected error happened that shouldn't repeat blindly.
- You've done 5 iterations in this loop run (track via
  `$REPO_ROOT/.mstack-work-next-plan.count`; reset if older than 1 hour).
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
"mstack-work-next-plan: backlog clear (or 5-iteration cap reached). N plans done this run. Check git log --oneline -N. Run /mstack-changelog when ready."
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
re-run `/mstack-work-next-plan`. The skill is idempotent on plan state — only
the picker's `status: pending` filter matters.
