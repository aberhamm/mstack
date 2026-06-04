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
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
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

## Step 1: Understand the goal

Read the user's input. If it's clear and specific enough to break down, proceed.
If ambiguous, ask clarifying questions via AskUserQuestion:

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

1. Read `CLAUDE.md` for project conventions, architecture, and constraints.
2. Read the directory structure to understand the project shape.
3. If the goal involves existing features, read the relevant source files.
4. Check existing plans in `docs/plans/` (or `plans/`) **and**
   `docs/plans/archive/` (or `plans/archive/`). Don't duplicate
   work that's already planned or done (including archived plans).
5. Read `$REPO_ROOT/.mstack/learnings.jsonl` if it exists to apply prior
   knowledge about this codebase.

## Step 3: Design the plan breakdown

### Step 3.0: Choose decomposition mode

Before decomposing, ask the user how to approach it via AskUserQuestion:

```
How should I approach this decomposition?

A) Explore: Generate 3 competing decompositions from different angles, pick the best
B) Direct: Single-pass decomposition (faster, good when the structure is obvious)
```

Map: **Explore** -> divergent mode (Step 3a), **Direct** -> single-pass mode (Step 3b).

---

### Step 3a: Divergent decomposition (Explore mode)

When the user chooses Explore, generate 3 independent candidate decompositions under
different architectural frames, score them, and present the best one with notable
alternatives.

#### 3a.1: Read decomposition frames

Resolve and read the decomposition frame definitions:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
FRAMES_FILE="$MSTACK_ROOT/skills/mstack-shared/cognitive-frames.md"
cat "$FRAMES_FILE"
```

If the frames file is not found, use the inline definitions below directly.
Use the three decomposition frames defined there:

1. **Minimize Coupling** -- each plan touches one module, explicit data contracts, no implicit dependencies
2. **Maximize Parallelism** -- minimize the critical path, fan-out over serial chains, split to enable concurrency
3. **Simplest Thing That Works** -- one verifiable outcome per plan, no bundled features, minimal scope per plan

#### 3a.2: Generate 3 independent candidates

For each decomposition frame, generate a complete plan breakdown independently.
Each candidate must meet the same quality bar as single-pass mode:

- Plan list with titles, 1-sentence descriptions, dependency relationships
- Execution order (which plans run in parallel vs. sequential)
- Review assignments (which plans need ceo/eng/design review and why)
- DAG structure with explicit blocked-by edges

**Independence requirement:** Generate each candidate in a separate agent call to ensure
independence. Each agent receives only the goal description, the codebase research from
Step 2, and its assigned decomposition frame. No agent has visibility into other
candidates' output. This prevents anchoring bias where later candidates converge toward
the first.

Agent prompt template for each candidate:

```
You are decomposing a goal into an ordered backlog of implementation plans.
Use the following decomposition frame to guide your architectural decisions:

FRAME: <frame name>
<frame checklist and behavioral bias from cognitive-frames.md>

GOAL: <the user's goal from Step 1>

CODEBASE CONTEXT: <summary from Step 2: project structure, existing code, conventions>

EXISTING PLANS: <any existing plans that must not be duplicated>

Produce a complete plan breakdown as a DAG:
- Each plan: number, title, 1-sentence description, blocked-by list, review type
- Plans should be 1-3 hours of focused work each
- Plans must be independently shippable (no broken intermediate states)
- Front-load hard decisions (schema, API contracts, architecture)

Output the breakdown as a numbered list with blocked-by edges and review assignments.
```

#### 3a.3: Critic scoring

After all 3 candidates return, score each candidate on 4 axes (1-10 scale):

| Axis | What it measures | Better = |
|------|-----------------|----------|
| **Dependency depth** | Longest chain in the DAG | Shallower (fewer sequential hops) |
| **Parallelism potential** | Number of plans that can run concurrently at peak | More concurrent plans |
| **Scope-fit per plan** | How well each plan fits the 1-3 hour sweet spot | All plans in range, none too large or trivially small |
| **Risk distribution** | Whether critical decisions are spread across plans or concentrated | More distributed (no single plan is a chokepoint for judgment calls) |

Sum the 4 scores for each candidate. The highest-scoring candidate wins.
In case of a tie, prefer the candidate with the shallowest dependency depth
(most parallelizable).

#### 3a.4: Reconciliation validation

Take the winning candidate and validate before presenting:

1. **No circular dependencies:** Walk the DAG and confirm no plan transitively
   depends on itself. If cycles exist, break them by reordering or splitting.
2. **No scope gaps:** Map every acceptance criterion from the user's goal to at
   least one plan. If any criterion is uncovered, add a plan or expand an existing one.
3. **No conflicting assumptions:** Check that no two plans assume contradictory
   things about shared resources (same file modified differently, conflicting schema
   choices, incompatible API designs). If conflicts exist, resolve by adding an
   explicit contract plan early in the DAG.
4. **Stable plan ordering:** If the critic scoring suggests a different sequencing
   than the candidate proposed (e.g., a plan scored high on risk should be earlier),
   reorder accordingly.

#### 3a.5: Notable alternatives

After reconciliation, prepare a "Notable alternatives" section that highlights
key structural differences from the non-winning candidates. This goes into the
Step 4 presentation. Format:

```
Notable alternatives (from other decompositions):
  - Candidate B (<frame name>) proposed <key difference>, which <tradeoff>
  - Candidate C (<frame name>) proposed <key difference>, which <tradeoff>
```

Include only differences that represent genuine architectural alternatives the user
might want to revisit, not minor ordering variations.

After completing 3a.5, proceed to Step 3.5 (multi-model structural critique) with
the winning candidate as the breakdown.

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

After designing the breakdown but before presenting it, fan out to
available external models for blind structural critique. This catches
decomposition blind spots that a single model misses. The critique is
on the plan structure (scope, ordering, dependencies, gaps), not on
format or implementation details. Plan-doctor handles those later.

### Discovery

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
```

Two critique channels, run in parallel when available:

1. **Codex** (if binary exists): shell out to `codex exec`
2. **Sonnet sub-agent**: spawn via Agent tool with `model: "sonnet"`

If Codex is unavailable, the Sonnet sub-agent still runs (single
external perspective is still valuable). If neither is available (no
codex binary, Agent tool fails), skip this step and proceed to Step 4.

### Codex critique (if available)

Build the prompt with the filesystem boundary and the breakdown:

```bash
TMPERR=$(mktemp "${TMPDIR:-/tmp}/codex-plan-err-XXXXXX.txt")
codex exec "IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. Stay focused on repository code only.

You are reviewing a plan decomposition for autonomous AI execution. The goal and proposed breakdown are below. Your job is to find structural problems only:

- Missing plans: are there gaps where one plan's output doesn't connect to the next plan's input?
- Wrong dependencies: are any blocked-by edges missing or incorrect? Would any plan fail because something it needs hasn't been built yet?
- Scope problems: are any plans too large for a single autonomous execution (more than 3 hours of focused work)? Are any too trivially small?
- Unstated assumptions: does any plan assume something that isn't produced by an earlier plan or isn't already in the codebase?
- Ordering risks: should any plan be earlier because it de-risks the rest?

Do not critique formatting, naming, or implementation approach. Only structural decomposition issues.

GOAL: <the user's goal>

PROPOSED BREAKDOWN:
<the plan breakdown table from Step 3>

Report only real problems. If the breakdown is solid, say so in one line." \
  -s read-only -c 'model_reasoning_effort="high"' --enable web_search_cached \
  < /dev/null 2>"$TMPERR"
```

Use `timeout: 300000` on the Bash call.

### Sonnet sub-agent critique

Spawn an Agent with `model: "sonnet"` and the same structural focus:

```
prompt: "You are reviewing a plan decomposition for autonomous AI execution.
The user's goal is: <goal>

The proposed breakdown is:
<the plan breakdown table from Step 3>

The codebase is: <project name, key files, structure summary from Step 2>

Find structural problems only:
- Missing plans or gaps between plans
- Wrong or missing dependency edges
- Plans too large or too small for autonomous execution
- Unstated assumptions not covered by earlier plans or the existing codebase
- Ordering risks (should something be earlier to de-risk?)

Do not critique formatting, naming, or implementation approach. Only
structural decomposition issues. If the breakdown is solid, say so in
one line. Be direct, be specific, name which plan numbers are affected."
```

### Synthesize

After both return, review their feedback:

- If both say the breakdown is solid, proceed to Step 4 as-is.
- If either flags real issues, revise the breakdown to address them
  before presenting to the user.
- If they contradict each other, use your judgment. Include a note
  in Step 4 about the disagreement so the user can weigh in.

In the Step 4 presentation, add a one-line note below the breakdown
table showing what was critiqued and by whom:

```
Structural critique: Codex + Sonnet (both clear)
```

or

```
Structural critique: Codex flagged missing migration plan between 002 and 003.
Sonnet flagged plan 005 scope too large. Both addressed in revised breakdown.
```

If critique was skipped (no external models available), note:

```
Structural critique: skipped (no external models available)
```

## Step 4: Present the breakdown for approval

Show the user the proposed plan breakdown as a table:

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

Pick the next available id (same logic as `mstack-plan-new` Step 2).
Scan both `$PLANS_DIR/*.md` and `$PLANS_DIR/archive/*.md` to find the
highest existing ID, ensuring no duplicates with archived plans.

For each plan in the approved breakdown, read the template from
the plan template (check `~/.config/skillshare/skills/mstack-run/plan-template.md`
first, fall back to `~/.claude/skills/mstack-run/plan-template.md`) and write a
complete plan file with:

- **Frontmatter**: id, title, status (pending or blocked), blocked-by,
  allows-migrations, needs-review, created
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

Plans that need review get `status: blocked` and appropriate `needs-review` value.
Plans that are ready get `status: pending`.

## Step 6: Summary

After writing all plan files, collect all created plan IDs into a list.
Print a summary that includes each plan's ID and title, then suggest a
scoped goal command using those specific IDs. **Never suggest "all pending
mstack plans are done or failed."** Always use the specific plan IDs.

```
Created plans:
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
  3. Run /goal complete mstack plans 001, 002, 003, 004, 005, 006, 007, 008
```

The goal command on step 3 must always list the exact plan IDs that were
just created (e.g., `/goal complete mstack plans 008, 009, 010, 011`).
This scopes execution to only the plans from this session, preventing
interference with plans created by other sessions or for other features.

Do not stage or commit the plan files. The user reviews first.
