---
name: mstack-plan-multi
description: |
  Take a high-level goal and decompose it into a full backlog of ordered,
  dependency-wired plan files ready for mstack-plan-doctor and
  mstack-run. Multi-model structural critique (Codex + Sonnet) catches
  decomposition blind spots before plans are finalized.
argument-hint: "<high-level goal or feature description>"
triggers:
  - create a plan
  - plan for
  - break this down into plans
  - decompose this
  - plan out
  - build a plan set
  - plan this feature
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
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

You are designing a complete plan backlog from a high-level goal. Your job:
understand what the user wants to build, research the existing codebase, then
produce a set of ordered plan files with dependencies, ready for review and
autonomous execution.

User input (the goal):

```
$ARGUMENTS
```

## Auto-init

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

## Philosophy

- **You are the initiator, not the implementer.** Design the work breakdown;
  don't write code.
- **Plans should be independently shippable.** Each plan produces a working
  increment. No plan should leave the codebase in a broken intermediate state.
- **Dependency ordering matters.** Later plans build on earlier ones. Get the
  foundations right.
- **Right-size each plan.** Too small (rename a variable) wastes overhead.
  Too large (build the entire feature) defeats the purpose of autonomous
  execution. Sweet spot: 1-3 hours of focused human work = one plan.
- **Front-load the hard decisions.** Plans that require judgment calls (schema
  design, API contracts, architecture patterns) go early and get `needs-review`.
  Mechanical follow-on plans can be `none`.

## Step 0: Is this plan-sized at all?

Before decomposing anything, check that a plan is the right instrument. Being
in a plan-driven repo is not a reason to plan every edit — a plan file plus a
doctor pass plus an execution iteration costs more than a small change does,
and it buries the real backlog in noise.

Proceed with decomposition only if at least one is true:

- The work splits into steps that must land in a specific order.
- It touches a seam other work depends on, or carries real rollback risk.
- It genuinely needs an eng/design/CEO review before implementation.
- The user wants it *queued* for autonomous execution rather than done now.

If none hold — a typo, a one-line fix, a doc or comment correction, a config
value, a rename, a missing test — **stop and say so** rather than scaffolding
a plan anyway:

```
This looks small enough to just do (<one line on why>). Want me to make the
change directly, or still queue it as a plan?
```

Then, if the user says do it, do it — you are allowed to leave this skill and
make the change. Scaffolding an unwanted plan is the more expensive mistake:
a small change done directly is trivially reverted, while a stray plan file
has to be triaged, reviewed, and retired.

This applies with extra force right after a plan or goal completes, when the
pull toward "I'll add a plan for that" is strongest and least justified.
Follow-up polish surfaced by a just-finished plan is a follow-up, not the next
plan id.

## Step 1: Understand the goal

Read the user's input. If it's clear and specific enough to break down, proceed.
If ambiguous, ask clarifying questions directly; use AskUserQuestion when the
host provides it:

- What's the end-state? What does "done" look like?
- What exists already? (Or is this greenfield?)
- Are there constraints? (Timeline, tech stack, compatibility, existing patterns)
- What's out of scope? (Explicitly exclude to prevent plan creep)
- Who's the user of this feature? (Helps write acceptance criteria)

Keep it to 2-4 questions max. Don't interrogate.

## Step 2: Research the codebase

Read the project to understand what exists:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
```

1. Read `AGENTS.md` first and `CLAUDE.md` if present for project
   conventions, architecture, and constraints.
2. Read the directory structure to understand the project shape.
3. If the goal involves existing features, read the relevant source files.
4. Check existing plans in `docs/plans/` (or `plans/`) **and**
   `docs/plans/archive/` (or `plans/archive/`). Don't duplicate
   work that's already planned or done (including archived plans).
5. Read `$REPO_ROOT/.mstack/learnings.jsonl` if it exists to apply prior
   knowledge about this codebase.

## Step 3: Design the plan breakdown

### Step 3.0: Choose decomposition mode

Before decomposing, ask the user how to approach it; use AskUserQuestion when
the host provides it:

```
How should I approach this decomposition?

A) Explore: Generate 3 competing decompositions from different angles, pick the best
B) Direct: Single-pass decomposition (faster, good when the structure is obvious)
```

Map: **Explore** -> divergent mode (Step 3a), **Direct** -> single-pass mode (Step 3b).

---

### Step 3a: Divergent decomposition (Explore mode)

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-plan-multi" ] && { SKILL_DIR="${_skill_base}/mstack-plan-multi"; break; }
done
```

> **Read** `"$SKILL_DIR/references/divergent-decomposition.md"` before proceeding.

After completing Step 3a, proceed to Step 3.5 (multi-model structural critique).

---

### Step 3b: Single-pass decomposition (Direct mode)

When the user chooses Direct, use the existing single-pass decomposition below.
This is identical to the current behavior with no additional cost or latency.

Produce a breakdown with:

1. **Plan list**: each plan gets a title, 1-sentence description, and
   dependency relationships.
2. **Execution order**: which plans can run in parallel vs. which must
   be sequential.
3. **Review assignments**: which plans need ceo/eng/design review and why.

Structure your thinking as a DAG (directed acyclic graph):

```
001 - Set up database schema [eng review]
002 - Create API endpoints [blocked-by: 001, eng review]
003 - Build UI components [blocked-by: 001, design review]
004 - Wire UI to API [blocked-by: 002, 003]
005 - Add authentication [blocked-by: 002, eng review]
006 - Integration tests [blocked-by: 004, 005]
```

**Heuristics for splitting:**
- Separate schema/data-model work from application logic
- Separate backend from frontend (they can parallelize)
- Separate core functionality from edge cases/polish
- Put tests in the same plan as the code they test (not separate)
- Infrastructure/config changes get their own plan if non-trivial

After completing 3b, proceed to Step 3.5 (multi-model structural critique).

## Step 3.5: Multi-model structural critique

```bash
for _skill_base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_skill_base}/mstack-plan-multi" ] && { SKILL_DIR="${_skill_base}/mstack-plan-multi"; break; }
done
```

> **Read** `"$SKILL_DIR/references/structural-critique.md"` before proceeding.

## Step 4: Present the breakdown for approval

Show the user the proposed plan breakdown as a table, then explain every plan
in plain language underneath it.

**The table alone is not the breakdown.** It is an index. Never present a bare
table of titles, dependency numbers and status codes as the whole answer. After
the table, each plan gets a short paragraph: what problem it fixes, how the user
would notice that problem, and what the change does. File paths and symbol names
are supporting detail inside those paragraphs, never a substitute for them.

```
Plan Backlog: "Multi-tenant billing system"
═══════════════════════════════════════════════════════════════
  #   Title                          Depends on   Review
  1   Design billing schema          none         eng
  2   Stripe webhook integration     1            eng
  3   Usage metering service         1            eng
  4   Billing UI components          1            design
  5   Invoice generation             2, 3         none
  6   Customer portal                4, 5         design
  7   Billing admin dashboard        5            none
  8   E2E billing flow tests         6, 7         none

8 plans. 3 need eng review, 2 need design review.
Estimated execution: plans 1-3 are the critical path.

1 — Design billing schema
Right now there is nowhere to record which customer is on which plan, so every
other billing feature has to invent its own storage. This adds the tables for
customers, subscriptions and invoices, which everything after it reads from.

2 — Stripe webhook integration
When a card payment fails or a subscription renews, Stripe tells us and nobody
is listening, so an account stays "active" after the customer stopped paying.
This adds the endpoint that receives those events and updates the subscription.

5 — Invoice generation
Customers get charged but never receive a document saying what for, which makes
disputes unresolvable. This turns a month of metered usage into a numbered
invoice with line items, and needs both the webhook (2) and the meter (3) first.
```

Ask: **"Does this breakdown look right? Any plans to add, remove, merge, or reorder?"**

If the user wants changes, iterate. When they approve, proceed to Step 5.

## Step 5: Write the plan files

Resolve the plans directory:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
if [ -d "$REPO_ROOT/docs/plans" ]; then
  PLANS_DIR="$REPO_ROOT/docs/plans"
elif [ -d "$REPO_ROOT/plans" ]; then
  PLANS_DIR="$REPO_ROOT/plans"
else
  PLANS_DIR="$REPO_ROOT/docs/plans"
  mkdir -p "$PLANS_DIR"
fi
```

### Slug derivation (goal name)

Before writing any files, derive a kebab-case **goal slug** from the user's
goal description. This slug is stamped into every plan in the batch and used
in the suggested `/goal` command.

**Custom slug detection (check first):** If the user's goal text contains a
`goal:` or `slug:` token followed by non-whitespace, extract everything from
after the colon to the next whitespace (or end of string). Use that value
verbatim as the slug — skip the auto-derivation steps below.

**Auto-derivation algorithm** (when no custom slug is provided):

1. Lowercase the entire goal description.
2. Strip all non-alphanumeric, non-space characters (remove punctuation,
   symbols, non-ASCII characters).
3. Split into words on whitespace.
4. Filter out stop words using single-word matching (see list below).
5. Take the first 4–6 meaningful words from what remains.
6. Join with hyphens.
7. Truncate after the last complete hyphen-separated token that fits
   within 40 characters. (Never cut a word in half.)

If the result is empty after filtering (e.g., the goal was entirely stop
words), fall back to the first 3 words of the original goal (lowercased,
joined with hyphens, truncated to 40 chars).

<!-- STOP-WORD LIST — extend as needed -->
```
a, an, the, to, for, from, in, on, with, by,
and, or, but,
add, create, build, implement, make, set, up,
update, fix, refactor, enable, disable, migrate, support
```
<!-- END STOP-WORD LIST -->

**Examples:**

| Goal input | Slug |
|---|---|
| "Add Stripe webhook retry logic" | `stripe-webhook-retry-logic` |
| "Implement user authentication and session management" | `user-authentication-session-management` |
| "Fix the broken CSV export" | `broken-csv-export` |
| "plan this, goal: wh-retry" | `wh-retry` (custom slug) |

Store the derived slug — it will be used in the frontmatter and summary.

---

Pick the next available id (same logic as `mstack-plan-new` Step 2).
Scan both `$PLANS_DIR/*.md` and `$PLANS_DIR/archive/*.md` to find the
highest existing ID, ensuring no duplicates with archived plans.

For each plan in the approved breakdown, read the template from
the plan template (check `~/.config/skillshare/skills/mstack-run/plan-template.md`
first, then `~/.agents/skills/mstack-run/plan-template.md`,
`~/.codex/skills/mstack-run/plan-template.md`, and
`~/.claude/skills/mstack-run/plan-template.md`) and write a
complete plan file with:

- **Frontmatter**: id, title, status (pending or blocked), blocked-by,
  goal, allows-migrations, needs-review, review-required, created.
  Whenever a plan is assigned any review, stamp `review-required:` with
  that same set alongside `needs-review:` (051-style): `needs-review` is
  the MUTABLE tracker reviewers clear as they go, `review-required` is the
  IMMUTABLE declared gate the completion check reads, stamped ONCE here at
  authoring and never cleared or shrunk. Either `needs-review: <set>` +
  `review-required: <set>` with `status: blocked` (review must precede
  pickup), or `needs-review: none` + `review-required: <set>` with
  `status: pending` (review required only at completion). When no review is
  assigned, omit `review-required:` rather than stamping an empty value.
  Include `goal: <slug>` (the slug derived above) in every plan's
  frontmatter, placed after `priority:` (if present) and before
  `allows-migrations:`.
- **Plain-English Summary**: immediately after frontmatter, write a 2–4
  sentence non-technical description of the problem and outcome, followed by
  `**What changes in the code:**` with a plain-English explanation of the
  implementation. It must let a reader understand both what changes and why
  without decoding file paths, symbols, or framework jargon; put those details
  in Design instead.
- **Requirements**: concrete problem statement + acceptance criteria
  (real checkboxes, not placeholders)
- **Design**: files expected to change (inferred from codebase research),
  approach notes, out of scope
- **Tasks**: 3-8 ordered implementation steps (real, not `...`)
- **Verification**: what to test beyond the default gate

**Quality bar:** Each plan should be specific enough that `mstack-run`
can implement it without asking questions. If you can't write concrete acceptance
criteria, the plan is too vague. Break it down further or flag it for the user.

**Testing approach line:** Every generated plan must include a "Testing
approach:" line in the Design section stating the verification strategy:

- `Testing approach: unit-only` -- for plans touching only internal
  logic, utilities, or libraries with no user-facing surface.
- `Testing approach: E2E` -- for plans touching API endpoints, backend
  services, or data pipelines that can be tested via integration tests.
- `Testing approach: browser-based` -- for plans touching pages,
  components, routes, templates, or any web-facing code.

Default mapping:
- Plans touching `pages/`, `components/`, `routes/`, `templates/`,
  `*.tsx`, `*.vue`, `*.html`, `*.css`, `*.svelte`, `app/` -> `browser-based`
- Plans touching API endpoints, `api/`, `server/`, `handlers/` -> `E2E`
- Plans touching only internal logic, `lib/`, `utils/`, `helpers/` -> `unit-only`

This makes the testing decision explicit and visible to plan-doctor
validation and mstack-run execution.

**Verification generation rules:** When generating the `## Verification`
section for each plan, detect available testing infrastructure and
generate appropriate check types:

1. **Detect gstack:** Check if gstack's `/browse` skill is available:
   `test -f ~/.config/skillshare/skills/browse/SKILL.md` or
   `test -f ~/.config/skillshare/skills/gstack/browse/SKILL.md` or
   `test -f ~/.agents/skills/browse/SKILL.md` or
   `test -f ~/.agents/skills/gstack/browse/SKILL.md` or
   `test -f ~/.codex/skills/browse/SKILL.md` or
   `test -f ~/.codex/skills/gstack/browse/SKILL.md` or
   `test -f ~/.claude/skills/browse/SKILL.md` or
   `test -f ~/.claude/skills/gstack/browse/SKILL.md`
2. **If gstack available and plan is web-facing:** Generate `[browse]`
   checks referencing the page or route. Format:
   `[browse] <path> verify '<expected content or behavior>'`
3. **If gstack not available:** Check for E2E frameworks in the project:
   - Playwright: `playwright.config.*` or `@playwright/test` in dependencies
   - Cypress: `cypress.config.*` or `cypress/` directory
4. **If E2E framework exists:** Generate `[cmd]` checks using the
   framework (e.g., `[cmd] npx playwright test --grep '<test name>'`)
5. **If neither gstack nor E2E framework:** Generate `[cmd]` checks with
   `curl` for API endpoints, or flag that the plan needs manual
   verification setup with a comment in the Verification section.

At least one plan in every backlog that involves UI or API endpoints must
include E2E-level verification (not just unit-level grep/test-f checks).

Plans that need review get `status: blocked` and the appropriate
`needs-review` value, plus a matching `review-required:` stamp.
Plans that are ready get `status: pending`.

## Step 6: Summary

After writing all plan files, collect all created plan IDs into a list.
Print a summary that includes each plan's ID and title, the derived goal
slug, and suggest a goal-based command as the **primary** execution command.
**Goal-capable harness rule:** If the current harness supports a native
`/goal` command, the plan-execution recommendation MUST be the goal-scoped
form (`/goal complete <slug> mstack plans`). Do not put a `/mstack-run` command
beside it as an alternative: it performs one iteration and defeats the
unattended loop. Only in a harness without native goals may the output fall
back to a scoped `/mstack-run` command. An explicit project safety rule that
requires a watched manual iteration remains an exception.

The whole-backlog form (`/goal all pending mstack plans are done or failed`)
stays valid everywhere else; it is just the wrong default right after
decomposing one goal, because it would sweep in unrelated pending plans.

The primary command uses the goal name (the slug derived in Step 5).

```
Created plans (goal: billing-schema-webhooks):
  001  Design billing schema              [blocked, needs: eng]
  002  Stripe webhook integration          [blocked, needs: eng, depends: 001]
  003  Usage metering service              [blocked, needs: eng, depends: 001]
  004  Billing UI components               [blocked, needs: design, depends: 001]
  005  Invoice generation                  [pending, depends: 002, 003]
  006  Customer portal                     [blocked, needs: design, depends: 004, 005]
  007  Billing admin dashboard             [pending, depends: 005]
  008  E2E billing flow tests              [pending, depends: 006, 007]

Next steps:
  1. Review and edit plans (especially Requirements and Design sections)
  2. Run /mstack-plan-doctor to validate and run pending reviews
  3. Run /goal complete billing-schema-webhooks mstack plans
```

The primary goal command on step 3 must use the derived slug
(e.g., `/goal complete <slug> mstack plans`). This scopes execution to only
the plans from this session, preventing interference with plans created by
other sessions or for other features.

Do not stage or commit the plan files. The user reviews first.
