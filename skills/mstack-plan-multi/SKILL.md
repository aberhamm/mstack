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
4. Check existing plans in `docs/plans/` (or `plans/`). Don't duplicate
   work that's already planned or done.
5. Read `$REPO_ROOT/.mstack/learnings.jsonl` if it exists to apply prior
   knowledge about this codebase.

## Step 3: Design the plan breakdown

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

Plans that need review get `status: blocked` and appropriate `needs-review` value.
Plans that are ready get `status: pending`.

## Step 6: Summary

After writing all plan files, print:

```
Created N plans in docs/plans/:
  001-design-billing-schema.md          [blocked, needs: eng]
  002-stripe-webhook-integration.md     [blocked, needs: eng, depends: 001]
  003-usage-metering-service.md         [blocked, needs: eng, depends: 001]
  004-billing-ui-components.md          [blocked, needs: design, depends: 001]
  005-invoice-generation.md             [pending, depends: 002, 003]
  006-customer-portal.md                [blocked, needs: design, depends: 004, 005]
  007-billing-admin-dashboard.md        [pending, depends: 005]
  008-e2e-billing-flow-tests.md         [pending, depends: 006, 007]

Next steps:
  1. Review and edit plans (especially Requirements and Design sections)
  2. Run /mstack-plan-doctor to validate and run pending reviews
  3. Run /goal all pending mstack plans are done or failed
```

Do not stage or commit the plan files. The user reviews first.
