---
name: mstack-plan-doctor
description: |
  Validate plan files against mstack-new-plan / mstack-work-next-plan format,
  find gaps, and run any pending reviews (eng, design, CEO). Accepts a specific
  plan id or file, or audits all plans in the plans directory. Uses sub-agents
  to parallelize deep validation across plans.
argument-hint: "[<plan-id or filename>]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
  - Skill
  - Agent
---

You are auditing plan files for compatibility with the `mstack-work-next-plan`
autonomous worker. Optionally scope to a single plan; default is all plans.

User input (optional — a plan id like `042`, a filename like `042-my-feature.md`,
or blank for all):

```
$ARGUMENTS
```

## Step 0 — Status dashboard

Before validation, display a status overview. Resolve the plans directory:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ -d "$REPO_ROOT/docs/plans" ]; then
  PLANS_DIR="$REPO_ROOT/docs/plans"
elif [ -d "$REPO_ROOT/plans" ]; then
  PLANS_DIR="$REPO_ROOT/plans"
fi
```

If `$PLANS_DIR` exists, scan all `*.md` files and build a table:

```
Plan Backlog Status
═══════════════════════════════════════════════════════════════════════════════
  ID    Title                         Status                  Review    QA
  042   Add user avatars              ✅ done                 unreviewed  automated
  043   Redesign settings page        ✅ done                 ✓ reviewed  automated,e2e,browser
  044   API rate limiting             🔒 blocked (042)        —           —
  045   Fix scraper payloads          ❌ failed               —           —
  046   Migrate user table            🔄 in-progress          —           —
  047   Add dark mode                 📋 needs review: eng    —           —
  048   Payment webhooks              ✅ done                 unreviewed  automated,e2e

Summary: 3 done (2 unreviewed, 1 without browser QA), 1 ready, 1 blocked, 1 failed, 1 in-progress, 1 awaiting review
```

For done plans, the **Review** and **QA** columns show:
- **Review**: `unreviewed` or `✓ reviewed` — whether the human has personally
  examined the shipped code
- **QA**: comma-separated list of testing completed:
  - `automated` — verification gate passed (typecheck/lint/unit tests)
  - `e2e` — end-to-end integration tests
  - `browser` — browser-based QA (scripted or manual)
  - `none` — no testing beyond implementation

**"Ready"** = `status: pending` AND `needs-review: none` AND all `blocked-by`
deps are `status: done`. This matches exactly what `pick-next.sh` selects.

**Stale in-progress detection:** If any plan has `status: in-progress`, flag it:

```
⚠️  Plan 046 has status: in-progress but may be stale.
    A previous mstack-work-next-plan iteration likely crashed.
    Suggested fix: reset to status: pending to re-enter the queue.
```

**Dependency cycle detection:** If following `blocked-by` edges through non-done
plans forms a cycle, surface it here:

```
🔴 Dependency cycle: 048 → 049 → 048
   These plans will never be picked up — they are deadlocked.
```

End the dashboard with a pre-loop summary:

```
N plans ready for /loop /mstack-work-next-plan. M awaiting review. K need fixes.
```

Then proceed to validation.

## Step 1 — Locate plans

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ -d "$REPO_ROOT/docs/plans" ]; then
  PLANS_DIR="$REPO_ROOT/docs/plans"
elif [ -d "$REPO_ROOT/plans" ]; then
  PLANS_DIR="$REPO_ROOT/plans"
else
  echo "No plans directory found (checked docs/plans/ and plans/)."
  exit 0
fi
```

If the user specified a plan, resolve it to a single file (match by id prefix
or filename). If not found, report and stop. If no argument, collect all `*.md`
files in `$PLANS_DIR`.

## Step 2 — Validate with sub-agents

Spawn sub-agents to parallelize validation. The approach depends on plan count:

- **1-3 plans**: validate inline (no sub-agents needed)
- **4+ plans**: spawn parallel sub-agents, one per plan (max 3 concurrent)

Additionally, when validating all plans, spawn one **cross-plan consistency
agent** in parallel with the per-plan agents.

### Per-plan agent

Each per-plan agent receives the plan file path and performs deep validation:

**Prompt template for per-plan agent:**

> You are validating a plan file for the mstack-work-next-plan autonomous worker.
> Read the plan at `{plan_path}` and validate it against these criteria.
> Also read the project's codebase to verify claims made in the plan.
>
> **Frontmatter checks** (error if missing/invalid):
> - `id`: integer
> - `title`: non-empty string
> - `status`: one of pending, in-progress, done, failed, blocked
> - `blocked-by`: `[]` or list of ids
> - `allows-migrations`: true or false (warning if missing, defaults false)
> - `needs-review`: comma-separated combination of none, eng, design, ceo (warning if missing)
> - `created`: YYYY-MM-DD (warning if missing)
> - `completed`: required if status=done (warning)
> - `reviewed`: required if status=done — `false` or `true` (warning if missing, defaults false)
> - `qa`: required if status=done — comma-separated: `none`, `automated`, `e2e`, `browser` (warning if missing, defaults none)
> - `failed-reason` + `failed-at`: required if status=failed (warning)
>
> **Section structure** (error if missing):
> - `## Requirements` with acceptance criteria (`- [ ]` items, not placeholders)
> - `## Design` with `**Files expected to change:**` and `**Out of scope:**`
> - `## Tasks` with 2+ real numbered steps
> - `## Verification` (warning if missing)
>
> **Deep validation** (read the codebase to verify):
> - Do the files listed in "Files expected to change" actually exist? If a file
>   is listed but doesn't exist and the plan isn't creating it, flag as warning.
> - Are the acceptance criteria testable? Do they reference real endpoints,
>   screens, or behaviors that exist (or will exist based on other plans)?
> - Is the design section's approach feasible? Read the relevant source files
>   and check: does the plan's approach conflict with existing architecture?
>   Are there dependencies it doesn't mention?
> - Are the tasks concrete enough for autonomous execution? Could an agent
>   implement each step without asking clarifying questions?
>
> **Report format** — return a structured result:
> ```
> Plan {id} — "{title}"
> Status: {N} errors, {N} warnings
>
> ERRORS:
>   - {description}
>
> WARNINGS:
>   - {description}
>
> DEEP FINDINGS:
>   - {description with file references}
>
> VERDICT: ready | needs-fixes | needs-review
> ```

### Cross-plan consistency agent

Spawn one agent that reads ALL plan files together and checks:

**Prompt template:**

> You are checking cross-plan consistency for the mstack-work-next-plan backlog.
> Read all plan files in `{plans_dir}`. Check:
>
> 1. **Duplicate ids** — error if two plans share the same id
> 2. **Dangling blocked-by** — error if a blocked-by references a nonexistent id
> 3. **Dependency cycles** — error if following blocked-by through non-done plans
>    forms a cycle. Report the full path.
> 4. **Stale blocks** — info if a plan's blocked-by deps are all done but it's
>    still status: blocked or pending with unmet deps
> 5. **Review gate mismatch** — warning if needs-review != none but status is
>    pending (should be blocked)
> 6. **Orphan in-progress** — warning if status is in-progress (likely stale)
> 7. **Overlapping scope** — warning if two plans list the same files in
>    "Files expected to change" and neither depends on the other (merge conflict risk)
> 8. **Ordering gaps** — info if a plan modifies files that a later plan also
>    modifies but there's no dependency between them
> 9. **Missing coverage** — look at the full set of plans as a feature. Are there
>    obvious gaps? (e.g., plans create an API but no plan adds auth to it;
>    plans build UI but no plan adds tests for it)
>
> Report format:
> ```
> Cross-plan consistency: {N} errors, {N} warnings, {N} info
>
> ERRORS:
>   - {description}
>
> WARNINGS:
>   - {description}
>
> INFO:
>   - {description}
>
> COVERAGE GAPS:
>   - {description of what seems missing from the backlog}
> ```

### Collecting results

After all agents complete, merge their results into a unified report.

## Step 3 — Report

Print a summary table for each plan:

```
Plan 042 — "Add user avatars"  [2 errors, 1 warning]
  ERROR   missing `needs-review` in frontmatter
  ERROR   no ## Design section
  WARNING no acceptance criteria in Requirements
  DEEP    src/api/avatars.ts doesn't exist yet (plan should note it's creating this file)

Cross-plan: [1 warning]
  WARNING plans 043 and 045 both modify src/components/Settings.tsx with no dependency
```

Then a totals line:

```
Audited 12 plans: 3 with errors, 4 with warnings, 5 clean.
```

If all plans are clean, say so and move to Step 4.

If there are errors, ask the user: **"Fix the errors automatically?"**
- If yes, apply mechanical fixes (add missing fields with sensible defaults,
  add missing section headings with template placeholders). Do NOT invent
  requirements or design content — use the placeholder text from
  `~/.claude/skills/mstack-work-next-plan/plan-template.md` as the canonical
  source for defaults and section structure. Edit each file and report what
  changed.
- If no, skip to Step 4.

If there are orphan in-progress plans, ask: **"Reset stale in-progress plans
to pending?"**
- If yes, update `status: in-progress` → `status: pending` in each.

If there are coverage gaps:
- List each gap with a one-sentence description of what's missing.
- Print: **"Coverage gaps found. Run `/mstack-plan-architect` with the gaps
  below to design proper plans for them."**
- Format the gaps as a ready-to-paste argument for plan-architect:
  ```
  /mstack-plan-architect Fill gaps: 1) auth middleware for API endpoints in plans 002-003,
  2) integration tests for billing flow in plans 005-006
  ```
- **Do NOT scaffold placeholder plans.** The architect is the right tool for
  designing complete plans — the doctor diagnoses but does not prescribe.
- **Block the "ready for loop" verdict** until gaps are resolved. The summary
  (Step 5) must say "NOT ready for unattended execution" if gaps exist.

## Step 4 — Run pending reviews

After validation, check which plans have `needs-review` set to something
other than `none` AND `status: blocked` (or `status: pending` — either way
they need review before the worker picks them up).

For each such plan, list it:

```
Plans pending review:
  042 — "Add user avatars"         needs: ceo, eng, design
  045 — "Redesign settings page"   needs: design
  048 — "API rate limiting"        needs: eng
```

Then ask: **"Run pending reviews now?"**

If yes, for each plan in order:
- If `needs-review` includes `ceo`: invoke `/plan-ceo-review` (the gstack
  plan-ceo-review skill) **first** — scope decisions should precede eng/design
  review. Pass the plan file path as context.
- If `needs-review` includes `eng`: invoke `/plan-eng-review` (the gstack
  plan-eng-review skill). Pass the plan file path as context.
- If `needs-review` includes `design`: invoke `/plan-design-review` (the
  gstack plan-design-review skill). Pass the plan file path as context.
- After each review completes, if the reviewer approves, remove that
  reviewer's tag from `needs-review` (e.g., `ceo,eng` → `eng`). When all
  tags are cleared, set `needs-review: none` and if `status: blocked`,
  change to `status: pending` so the worker can pick it up.
- If the reviewer requests changes, leave `needs-review` and `status` as-is
  and report what the reviewer flagged.

If no, print the list and exit.

## Step 5 — Summary

Print a verdict:

**If no gaps, no errors, and no pending reviews:**
```
✅ Doctor complete. N plans ready for /loop /mstack-work-next-plan. Backlog is clear for unattended execution.
```

**If gaps exist:**
```
⚠️ Doctor complete. N plans ready, but M coverage gaps would leave the feature incomplete.
   Run /mstack-plan-architect to fill gaps before running unattended.
   NOT ready for unattended execution.
```

**If errors or pending reviews remain:**
```
⚠️ Doctor complete. N plans ready, M awaiting review, K need fixes.
   Resolve before running /loop /mstack-work-next-plan unattended.
```

**Post-execution tracking** (always show if any done plans exist):
```
Shipped plans attention tracker:
  Unreviewed: N plans (you haven't personally looked at these yet)
  QA coverage:
    automated only: N plans
    automated + e2e: N plans
    automated + e2e + browser: N plans (fully tested)
```

This section is informational — it doesn't block anything. It tells you
what shipped code still needs your eyes on it and what testing gaps remain
after pushing to remote.
