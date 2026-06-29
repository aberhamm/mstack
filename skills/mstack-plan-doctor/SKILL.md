---
name: mstack-plan-doctor
description: |
  Validate plan files against mstack-plan-new / mstack-run format,
  find gaps, and run any pending reviews (eng, design, CEO). Accepts a specific
  plan id or file, or audits all plans in the plans directory. Uses sub-agents
  to parallelize deep validation across plans.
argument-hint: "[<plan-id or filename>]"
triggers:
  - validate plans
  - check plans
  - review the backlog
  - are the plans ready
  - audit plans
  - doctor
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
  - Skill
  - Agent
---

You are auditing plan files for compatibility with the `mstack-run`
autonomous worker. Optionally scope to a single plan; default is all plans.

User input (optional, a plan id like `042`, a filename like `042-my-feature.md`,
or blank for all):

```
$ARGUMENTS
```

## Auto-init

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Discovery: check for review skills

```bash
[ -f ~/.config/skillshare/skills/plan-ceo-review/SKILL.md ] && echo "CEO_REVIEW: available" || echo "CEO_REVIEW: unavailable"
[ -f ~/.config/skillshare/skills/plan-eng-review/SKILL.md ] && echo "ENG_REVIEW: available" || echo "ENG_REVIEW: unavailable"
[ -f ~/.config/skillshare/skills/plan-design-review/SKILL.md ] && echo "DESIGN_REVIEW: available" || echo "DESIGN_REVIEW: unavailable"
```

If the gstack review skills are installed, use them for Step 4 reviews
(they provide richer interactive review flows). If not installed, fall
back to the built-in auto-decision framework below.

### Built-in auto-decision framework

When gstack review skills are unavailable, plan-doctor can still review
plans using 6 decision principles (from autoplan). Each decision the
reviewer encounters is classified and handled:

**Decision principles:**
1. **Choose completeness**: ship the whole thing, not a partial version
2. **Boil lakes**: fix everything in the blast radius
3. **Pragmatic**: the cleaner option wins ties
4. **DRY**: reject duplicates without mercy
5. **Explicit over clever**: obvious beats abstract
6. **Bias toward action**: merge beats deliberation

**Decision classification:**
- **Mechanical** (auto-decided silently): formatting, naming consistency,
  missing fields with obvious defaults. Applied without reporting.
- **Taste** (surfaced at the end): close calls where reasonable people
  disagree. Listed with the principle that decided them and why. The user
  can override.
- **User challenge** (never auto-decided): scope changes, architectural
  bets, removing features, anything one-way or irreversible. Always
  presented to the user for decision.

When running built-in reviews, present taste decisions at the end:

```
AUTO-DECISIONS (taste, override any you disagree with):
  T1. Kept the retry logic inline (principle: explicit > clever)
  T2. Merged plans 043+044 scope (principle: choose completeness)
  T3. Used existing auth pattern (principle: DRY)
```

## Step 0: Status dashboard

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
  ID    Pri   Title                         Status                  Review    QA
  042   -     Add user avatars              ✅ done                 unreviewed  automated
  043   -     Redesign settings page        ✅ done                 ✓ reviewed  automated,e2e,browser
  044   -     API rate limiting             🔒 blocked (042)        -           -
  045   1     Fix scraper payloads          ❌ failed               -           -
  046   -     Migrate user table            🔄 in-progress          -           -
  047   -     Add dark mode                 📋 needs review: eng    -           -
  048   -     Payment webhooks              ✅ done                 unreviewed  automated,e2e

Summary: 3 done (2 unreviewed, 1 without browser QA), 1 ready, 1 blocked, 1 failed, 1 in-progress, 1 awaiting review
```

For done plans, the **Review** and **QA** columns show:
- **Review**: `unreviewed` or `✓ reviewed`, indicating whether the human has
  personally examined the shipped code
- **QA**: comma-separated list of testing completed:
  - `automated`: verification gate passed (typecheck/lint/unit tests)
  - `e2e`: end-to-end integration tests
  - `browser`: browser-based QA (scripted or manual)
  - `none`: no testing beyond implementation

**"Ready"** = `status: pending` AND `needs-review: none` AND all `blocked-by`
deps are `status: done`. This matches exactly what `pick-next.sh` selects.

**Stale in-progress detection:** If any plan has `status: in-progress`, flag it:

```
⚠️  Plan 046 has status: in-progress but may be stale.
    A previous mstack-run iteration likely crashed.
    Suggested fix: reset to status: pending to re-enter the queue.
```

**Dependency cycle detection:** If following `blocked-by` edges through non-done
plans forms a cycle, surface it here:

```
🔴 Dependency cycle: 048 → 049 → 048
   These plans will never be picked up. They are deadlocked.
```

End the dashboard with a pre-loop summary:

```
N plans ready. M awaiting review. K need fixes.
```

## Step 0b: Testing infrastructure audit

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-plan-doctor"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-plan-doctor" ] && SKILL_DIR="${_skill_base}/mstack-plan-doctor"
done
```

> **Read** `"$SKILL_DIR/references/testing-audit.md"` for the full audit procedure
> (5-tier detection, output format, confidence levels, health gate integration).

Then proceed to validation.

## Step 1: Locate plans

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

## Step 1b: Choose review posture

Plan-doctor is the architect's tool. This is where the human shapes
the backlog before walking away. Ask the user what posture they want:

**Ask directly; use AskUserQuestion when the host provides it:**

```
How should I review this backlog?

A) Expand: "What would make this a 10-star version? What's left on the table?"
   Actively looks for missing capabilities, suggests new plans, challenges
   conservative scope. Best when you're early and exploring.

B) Selective: "Keep the scope, but cherry-pick one or two expansions"
   Holds the current plan count but flags 1-3 high-leverage additions
   that punch above their weight. Best for a solid backlog that might
   be leaving easy wins behind.

C) Hold: "Lock the scope. Maximum rigor on what's here."
   No new plans suggested. Focus entirely on quality: are the specs
   concrete enough? Are the dependencies right? Will the worker get
   stuck? Best when you're ready to run and want confidence.

D) Reduce: "Strip to essentials. What's the narrowest shippable thing?"
   Actively looks for plans that could be deferred or merged. Challenges
   anything that isn't on the critical path. Best when you need to ship
   fast or are unsure about the full scope.
```

Store the chosen posture; it affects scope decisions in Steps 2-4.

**How posture affects the review:**

| Aspect | Expand | Selective | Hold | Reduce |
|--------|--------|-----------|------|--------|
| Coverage gaps | Flag aggressively + suggest plans | Flag + suggest 1-3 cherry-picks | Flag but don't block | Ignore unless critical |
| Scope challenges | "Why not also..." | "Consider also..." | No scope changes | "Do you really need..." |
| Plan merging | Never (more granularity = better) | Merge if overlapping | Merge if overlapping | Aggressively merge |
| New plan suggestions | Yes, actively | 1-3 max, high-leverage only | Never | Never |
| Acceptance criteria bar | Must cover edge cases | Must cover happy path + key edges | Must cover happy path | Must cover critical path only |

**Regardless of posture**, the following always apply:
- **Autonomy-readiness** and **testability** are weighted highest
- Plans below 8/10 on autonomy-readiness are auto-fixed
- Plans without executable verification checks are blocked
- Learnings from previous executions are surfaced
- Mechanical errors are fixed automatically

## Step 2: Score each plan (0-10 on 5 dimensions)

Before the structural validation pass, score each pending/blocked plan on
five dimensions. This produces a quality radar that's more useful than
binary pass/fail.

### Capture the modified-plan baseline (PLAN_HASHES)

Before any scoring or auto-fix touches a file, snapshot the **content hash**
of every plan file. The re-validation loop (Step 4b) and the Step 5/Step 6
verdict gates use this baseline to learn EXACTLY which plans the doctor edited,
so re-validation runs only over changed files and never over the untouched
backlog.

```bash
# PLAN_HASHES: path -> content hash, captured BEFORE any edit phase.
declare -A PLAN_HASHES
while read -r _hash _path; do
  PLAN_HASHES["$_path"]="$_hash"
done < <(shasum "$PLANS_DIR"/*.md 2>/dev/null)
```

Use a **content hash** (`shasum`) of each plan file, NOT `git status
--porcelain`. Porcelain reports only the status class (` M`, `??`, etc.), so a
plan file that is already dirty or untracked BEFORE an edit keeps the same
status class AFTER the edit and would be missed — and during doctor-autonomy
work these plan files are frequently untracked. `shasum` compares actual file
content, is always available, and needs no git state. To derive the MODIFIED
set after an edit phase, recompute each plan's hash and treat any plan whose
hash differs from its `PLAN_HASHES` entry (or that is newly present) as
modified:

```bash
# After an edit phase: derive the changed set vs the current baseline.
MODIFIED_PLANS=()
while read -r _hash _path; do
  [ "${PLAN_HASHES["$_path"]:-}" != "$_hash" ] && MODIFIED_PLANS+=("$_path")
done < <(shasum "$PLANS_DIR"/*.md 2>/dev/null)
```

Re-capture `PLAN_HASHES` at the top of each Step 4b loop round so each round
sees ONLY the edits made since the previous round, not the cumulative diff.

### Dimensions

**Clarity (0-10):** Can someone who's never seen this codebase understand
what to build from the plan alone?
- 10: Acceptance criteria are specific and testable. Design names exact files,
  functions, and types. Tasks are ordered and concrete.
- 7: Requirements are clear but design is hand-wavy. A good developer could
  fill in the blanks.
- 4: Requirements are vague ("make it work"), design is missing key decisions,
  tasks are high-level bullets.
- 0: Template placeholders or empty sections.

**Testability (0-10):** Can the verification gate prove this plan worked?
- 10: Every acceptance criterion maps to a test. The plan specifies what
  to assert and how. Includes `[browse]` or `[e2e]` checks for web-facing plans.
- 7: Most criteria are testable but some require manual verification
  ("it looks right").
- 4: Tests would only cover the happy path. Edge cases in the requirements
  have no verification strategy.
- 0: No clear way to verify the plan succeeded.

**Testability cap for file-existence-only verification:**
If ALL verification checks in the plan's `## Verification` section are
file-existence (`test -f`) or string-matching (`grep`) only, cap the
testability score at a maximum of 5/10 regardless of how many checks exist.
These checks prove the worker wrote files, not that the feature works.
A plan must include at least one check that exercises the running
application (`[cmd]` with a functional test, `[status]`, `[browse]`, or
`[e2e]`) to score above 5.

**Web-facing testability error:**
If the plan touches web-facing files (detect from "Files expected to change":
`pages/`, `components/`, `routes/`, `templates/`, `*.tsx`, `*.vue`, `*.html`,
`*.css`, `*.svelte`, `app/`) AND has no `[browse]`, `[e2e]`,
`[cmd]` with `curl`/`httpie`/`playwright`/`cypress`, or `[status]` check:
flag as a **testability error** (the plan is not verifiable for web-facing
changes). If the project has no E2E framework detected (no `playwright.config.*`,
no `cypress.config.*`, no `cypress/` directory) AND gstack's `/browse` skill
is unavailable (no `browse/SKILL.md` or `gstack/browse/SKILL.md` under
`~/.config/skillshare/skills`, `~/.agents/skills`, `~/.codex/skills`, or
`~/.claude/skills`), downgrade to a
**warning** instead of an error.

**Scope-fit (0-10):** Is this plan the right size for autonomous execution?
- 10: One focused change. 2-8 files. Clear boundaries. A single commit
  message could describe it.
- 7: Coherent but touches multiple concerns. Could arguably be split but
  works as one unit.
- 4: Bundles unrelated changes or spans too many files. The worker will
  struggle to roll back cleanly on failure.
- 0: Epic-sized. Should be 3+ plans.

**Autonomy-readiness (0-10):** Can the mstack-run worker implement this
without asking a human for clarification?
- 10: Every decision is made in the plan. No ambiguity. The worker just
  executes.
- 7: One or two judgment calls, but a competent AI could resolve them
  from codebase context.
- 4: Multiple open questions. The worker would need to guess or ask.
- 0: The plan is a goal, not a spec. "Add authentication" with no design.

**Trap resistance (0-10):** Will this plan's approach actually work under
real-world conditions? Evaluates whether the chosen approach contains
patterns that are seductively simple but will fail in practice.

Evaluate by adopting a deliberately adversarial posture: "Assume this
plan's approach will fail. Find the patterns that look good on paper but
will break in practice."

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-plan-doctor"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-plan-doctor" ] && SKILL_DIR="${_skill_base}/mstack-plan-doctor"
done
```

> **Read** `"$SKILL_DIR/references/trap-resistance.md"` for the 5 trap categories
> with detection heuristics, scoring rubric, findings output format, and auto-fix
> procedure.

Plans scoring below 6/10 on trap resistance get an explicit warning with
the specific trap identified.

### Composite score formula

The composite score is a weighted average of all 5 dimensions:

```
composite = (clarity * 0.20) + (testability * 0.25) + (scope_fit * 0.20)
          + (autonomy_readiness * 0.25) + (trap_resistance * 0.10)
```

Default weights: clarity 20%, testability 25%, scope-fit 20%,
autonomy-readiness 25%, trap resistance 10%.

These weights are configurable via `.mstack/config.json` at the key
`health.weights.planning` (object with the 5 dimension names as keys,
values summing to 1.0). If the key is absent, the defaults above apply.

### Scoring output

For each plan, produce a scorecard:

```
Plan 042, "Add user avatars"
  Clarity:            8/10  (acceptance criteria are specific, design could name types)
  Testability:        9/10  (all criteria map to assertions)
  Scope-fit:          7/10  (touches 5 files across 2 packages; consider splitting)
  Autonomy-readiness: 6/10  (unclear which image library to use, decision needed)
  Trap resistance:    7/10  (minor: scope creep magnet, "Out of scope" section is thin)
  Composite:          7.3/10

  Trap findings:
    - "Thin scope boundary" [scope creep magnet]: add explicit out-of-scope items for
      avatar cropping, avatar history, and social avatar import

  What would make it a 10:
    - Clarity: name the exact TypeScript types for the avatar model
    - Autonomy: specify "use sharp for image processing" in the Design section
    - Trap resistance: flesh out the "Out of scope" section to prevent scope drift
```

The "what would make it a 10" section is always present. It turns the score
into actionable fixes. The trap findings section appears only when traps
are detected (score below 10).

**E2E suggestion in "what would make it a 10":**
If testability < 8 and the plan touches web-facing files (pages, components,
routes, templates, *.tsx, *.vue, *.html, *.css), always include this
suggestion in the "what would make it a 10" output:

```
  - Testability: add a [browse] or [e2e] check that verifies the feature
    works in a browser, not just that files exist
```

**Scoring emphasis by posture:**
- **Expand**: weight Clarity and Testability higher (need solid specs to expand scope)
- **Selective**: weight all equally
- **Hold**: weight Autonomy-readiness highest (will the worker get stuck?)
- **Reduce**: weight Scope-fit highest (can plans be merged or deferred?)

**Regardless of posture**, these always apply:
- Plans scoring below **8/10 on autonomy-readiness** are auto-fixed (see
  below) without asking. The architect's job is to make decisions; if the
  plan has open decisions, the doctor fills them from codebase analysis.
- Plans scoring below **7/10 on testability** trigger automatic verification
  check generation (see Verification auto-fix below).

### Auto-fix: autonomy-readiness

After scoring, if any plan scores below 8 on Autonomy-readiness,
**automatically fix it** without asking. Read the codebase to infer the
right decisions (check existing dependencies, conventions, sibling
implementations) and update each plan's Design section. Then re-score
to confirm improvement.

Log what was fixed:

```
Auto-fixed autonomy gaps:
  042, "Add user avatars": added "use sharp for image processing" to Design (was 6/10, now 9/10)
  045, "Redesign settings page": added mobile breakpoint spec to Design (was 5/10, now 8/10)
```

If a decision cannot be inferred from the codebase (genuinely ambiguous,
with two equally valid approaches with different tradeoffs), flag it as a
**user challenge** that requires the architect's input. These are the
only questions plan-doctor should ask.

### Testability auto-fix: generate [browse] checks for web-facing plans

After scoring, if a plan scores below 7/10 on testability AND touches
web-facing files (pages/, components/, routes/, templates/, *.tsx, *.vue,
*.html, *.css), automatically generate a `[browse]` check from the plan's
acceptance criteria. This supplements existing verification checks with
browser-level verification.

For each user-facing acceptance criterion (`- [ ]` item), generate a
`[browse]` check:
- Parse the criterion to identify the likely route/page and the expected
  visible outcome.
- Format: `[browse] <likely-route> verify '<key text from criterion>'`
- Example: acceptance criterion "page shows billing dashboard" becomes
  `[browse] /settings/billing verify 'Current Plan' text is visible`

Add the generated `[browse]` checks to the plan's `## Verification`
section. Re-score to confirm testability improved.

Log what was generated:
```
Auto-generated [browse] checks:
  042, "Add billing dashboard": added [browse] /settings/billing verify 'Current Plan' visible
    (testability was 4/10, now 8/10)
```

### Verification auto-fix

After scoring, if any plan's `## Verification` section is empty, contains
only placeholders, or has only `[manual]` items, and the plan does NOT have
`verification: health-only` in frontmatter, **automatically generate
executable checks** without asking. This is mandatory: plans without
executable verification are blocked from execution.

For each plan needing verification:
1. Read the `## Requirements` acceptance criteria (`- [ ]` items)
2. Read the `## Design` section for endpoints, commands, file paths
3. Infer appropriate checks:
   - API endpoints → `[status]` checks with expected codes
   - CLI commands → `[cmd]` checks
   - Output assertions → `[assert]` checks with expected strings
   - UI/visual requirements → `[manual]` (can't be automated, but at least
     one non-manual check is still required)
4. Write the generated checks into the plan's `## Verification` section
5. Re-score to confirm testability improved

Example generation:
```
Acceptance criteria: "GET /api/users returns 200 with a JSON array"
  → [status] curl -o /dev/null -sw '%{http_code}' localhost:3000/api/users → 200
  → [assert] curl -s localhost:3000/api/users | grep '^\['
```

Do not hallucinate checks for things the plan doesn't mention. Only
generate checks that directly map to stated acceptance criteria.

If no executable checks can be inferred (e.g., the plan is purely visual
with no testable endpoints or commands), flag it as an error and suggest
the architect add `verification: health-only` to the frontmatter or write
manual-to-automated check mappings.

### Auto-fix: trap resistance

After scoring, if any plan scores below 4 on trap resistance (high risk),
**automatically fix it** without asking. See the auto-fix procedure in
`references/trap-resistance.md` (loaded via Read directive above).

## Step 2b: Learnings check (feed failures back to the architect)

Before structural validation, search the learnings database for patterns
relevant to each pending plan. This surfaces pitfalls from previous plan
executions so the architect can adjust the design before walking away.

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
```

For each pending/blocked plan:
1. Extract the plan's title, file paths from "Files expected to change",
   and topic keywords from the Requirements section.
2. Search learnings for matches:
   ```bash
   bash "$SKILL_DIR/scripts/learnings.sh" search "<keyword>"
   bash "$SKILL_DIR/scripts/learnings.sh" search "<file path>"
   ```
3. For each matching learning with confidence >= 5, check if the plan's
   Design section accounts for it.

Surface matches as warnings in the plan's validation report:

```
Plan 042, "Add user avatars"
  LEARNING  [pitfall] ORM doesn't support composite upserts (from plan-034, confidence 8)
            → Design section doesn't mention this. The worker may hit this during implementation.
  LEARNING  [dependency] Image processing requires sharp to be installed (from plan-028, confidence 7)
            → Verify sharp is in package.json or add an install step to Tasks.
```

**Classification:**
- **Pitfall** learnings (type: pitfall) → WARNING: "The worker previously
  failed on this. Does the plan account for it?"
- **Dependency** learnings (type: dependency) → WARNING: "A prerequisite
  was discovered. Is it in the Tasks section?"
- **Convention** learnings (type: convention) → INFO: informational only,
  the worker will apply these automatically during implementation.
- **Pattern** learnings (type: pattern) → INFO: informational only.

Pitfall and dependency warnings affect the plan's **autonomy-readiness**
score: if the plan doesn't account for a relevant pitfall, deduct 1 point
from autonomy-readiness (the worker is likely to hit it again).

If no learnings database exists (`.mstack/learnings.jsonl` missing or empty),
skip this step silently.

## Step 2c: Multi-frame review

Review each pending/blocked plan through 3 deterministically-selected
cognitive frames to surface blind spots that single-perspective scoring misses.

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-plan-doctor"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-plan-doctor" ] && SKILL_DIR="${_skill_base}/mstack-plan-doctor"
done
```

> **Read** `"$SKILL_DIR/references/frame-review.md"` for the full multi-frame
> review procedure (setup, frame selection, evaluation, scoring integration,
> auto-fix, and scorecard update format).

If the cognitive frames file is not found, skip Step 2c and proceed to Step 3
(frame review is additive, not blocking). Each unaddressed **[critical]** finding
deducts 1 point from the plan's **autonomy-readiness** score.

## Step 3: Structural validation with sub-agents

Spawn sub-agents to parallelize validation. The approach depends on plan count:

- **1-3 plans**: validate inline (no sub-agents needed)
- **4+ plans**: spawn parallel sub-agents, one per plan (max 3 concurrent)

Additionally, when validating all plans, spawn one **cross-plan consistency
agent** in parallel with the per-plan agents.

### Per-plan agent

Each per-plan agent receives the plan file path and performs deep validation:

**Prompt template for per-plan agent:**

> You are validating a plan file for the mstack-run autonomous worker.
> Read the plan at `{plan_path}` and validate it against these criteria.
> Also read the project's codebase to verify claims made in the plan.
>
> **Frontmatter checks** (error if missing/invalid):
> - `id`: integer
> - `title`: non-empty string
> - `status`: one of pending, in-progress, done, failed, blocked
> - `blocked-by`: `[]` or list of ids
> - `priority`: integer (optional, defaults to id; used for execution ordering)
> - `allows-migrations`: true or false (warning if missing, defaults false)
> - `needs-review`: comma-separated combination of none, eng, design, ceo (warning if missing)
> - `created`: YYYY-MM-DD (warning if missing)
> - `completed`: required if status=done (warning)
> - `reviewed`: required if status=done, `false` or `true` (warning if missing, defaults false)
> - `qa`: required if status=done, comma-separated: `none`, `automated`, `e2e`, `browser` (warning if missing, defaults none)
> - `verification`: optional, `health-only` to opt out of executable verification checks (warning if set)
> - `review`: optional, `thorough` for 3-reviewer pipeline (defaults to standard 1-reviewer)
> - `failed-reason` + `failed-at`: required if status=failed (warning)
>
> **Section structure** (error if missing):
> - `## Requirements` with acceptance criteria (`- [ ]` items, not placeholders)
> - `## Design` with `**Files expected to change:**` and `**Out of scope:**`
> - `## Tasks` with 2+ real numbered steps
> - `## Verification` with at least one `[cmd]`, `[assert]`, or `[status]` check
>   (**error** if only `[manual]`, placeholder, or empty; plans without executable
>   verification cannot be trusted for unattended execution). The only exception:
>   if the plan's frontmatter has `verification: health-only`, downgrade to warning
>   (the architect explicitly accepts health-gate-only validation for this plan).
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
> **Learnings cross-reference** (if learnings were found in Step 2b):
> - For each relevant pitfall/dependency learning, check if the plan's
>   Design or Tasks sections account for it. If not, add to WARNINGS.
>
> **Report format**: return a structured result:
> ```
> Plan {id}, "{title}"
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

> You are checking cross-plan consistency for the mstack-run backlog.
> Read all plan files in `{plans_dir}`. Check:
>
> 1. **Duplicate ids**: error if two plans share the same id
> 2. **Dangling blocked-by**: error if a blocked-by references a nonexistent id
> 3. **Dependency cycles**: error if following blocked-by through non-done plans
>    forms a cycle. Report the full path.
> 4. **Stale blocks**: info if a plan's blocked-by deps are all done but it's
>    still status: blocked or pending with unmet deps
> 5. **Review gate mismatch**: warning if needs-review != none but status is
>    pending (should be blocked)
> 6. **Orphan in-progress**: warning if status is in-progress (likely stale)
> 7. **Overlapping scope**: warning if two plans list the same files in
>    "Files expected to change" and neither depends on the other (merge conflict risk)
> 8. **Ordering gaps**: info if a plan modifies files that a later plan also
>    modifies but there's no dependency between them
> 9. **Missing coverage**: look at the full set of plans as a feature. Are there
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

## Step 4: Report

Print a summary table for each plan:

```
Plan 042, "Add user avatars"  [2 errors, 1 warning]
  ERROR   missing `needs-review` in frontmatter
  ERROR   no ## Design section
  WARNING no acceptance criteria in Requirements
  DEEP    src/api/avatars.ts doesn't exist yet (plan should note it's creating this file)

Cross-plan: [1 warning]
  WARNING plans 043 and 045 both modify src/components/Settings.tsx with no dependency
```

Include the plan scores from Step 2 and frame review findings from Step 2c
alongside structural findings:

```
Plan 042, "Add user avatars"  [2 errors, 1 warning]  Score: 7.3/10
  Clarity: 8  Testability: 9  Scope-fit: 7  Autonomy: 6 (-1 frame: auth gap)
  Trap resistance: 7 (scope creep magnet: thin "Out of scope" section)
  Frames: Security Review, End User, Simplicity Advocate
  ERROR   missing `needs-review` in frontmatter
  ERROR   no ## Design section
  WARNING no acceptance criteria in Requirements
  DEEP    src/api/avatars.ts doesn't exist yet (plan should note it's creating this file)
  FIX     Autonomy: specify image library choice in Design section
  FIX     Trap resistance: flesh out "Out of scope" to prevent scope drift
  FRAME   [critical] Security Review: no auth middleware on upload endpoint
  FRAME   [advisory] End User: no loading state for avatar upload UX

Cross-plan: [1 warning]
  WARNING plans 043 and 045 both modify src/components/Settings.tsx with no dependency
```

Then a totals line:

```
Audited 12 plans: 3 with errors, 4 with warnings, 5 clean.
Average score: 7.8/10. Lowest: plan 042 (6/10 autonomy-readiness).
```

If all plans are clean, say so and move to Step 5.

If there are **mechanical errors** (missing frontmatter fields, missing
section headings), **fix them automatically** without asking. Apply sensible
defaults and use the plan template as the canonical source for section
structure. Log what was fixed.

If there are orphan in-progress plans, **reset them automatically** to
`status: pending`. Log: "Reset plan {id} from in-progress to pending
(stale from previous session)."

If there are coverage gaps, handle them based on the chosen posture:

**Expand posture:**
- List every gap, even speculative ones.
- Actively suggest new plans: "You're building an API but no plan adds rate
  limiting. You're adding a UI but no plan adds loading states."
- Format as a ready-to-paste `/mstack-plan-multi` argument.
- **Block the "ready for loop" verdict** until gaps are resolved.

**Selective posture:**
- List gaps but rank them by leverage. Highlight 1-3 that would most
  improve the shipped feature. Format the top picks as a ready-to-paste argument.
- Block verdict only for critical gaps (security, data integrity).

**Hold posture:**
- List gaps as informational only. Do NOT block the verdict.
- Print: "Coverage gaps noted (not blocking in Hold mode)."

**Reduce posture:**
- Only flag gaps that would cause the shipped code to be broken (not just
  incomplete). Actively suggest plans that could be deferred.
- Do NOT block the verdict for feature gaps.

In all postures:
- **Do NOT scaffold placeholder plans.** The backlog planner is the right
  tool for designing complete plans.
- Format gaps as a ready-to-paste `/mstack-plan-multi` argument.

## Step 4b: Re-validate modified plans (close the auto-fix loop)

The auto-fix phases (autonomy-readiness, testability, verification, trap
resistance, mechanical-error fixes, frame-finding fixes) and any review-applied
edits all transform a plan IN PLACE. The doctor validated v1; the fixers
produced v2; without this step v2 ships unvalidated, and a defect introduced by
a fix (e.g. a self-contradiction the fixer added) survives to execution because
nothing ever re-checked the post-edit state. Step 4b closes that loop: after
the edit phases, **re-validate the plans the doctor actually changed**.

### Derive the changed set, then re-validate only those plans

Using the `PLAN_HASHES` baseline captured at the start of Step 2, recompute each
plan file's hash and collect every plan whose hash differs (the `MODIFIED_PLANS`
set). Re-validation runs over EXACTLY this changed set — never the whole
backlog, so untouched plans incur no redundant work.

For each modified plan, re-run only the per-plan checks that its own edits could
have invalidated:

- the **Step 3 per-plan structural validation** (frontmatter, section
  structure, executable-verification requirement, deep codebase checks);
- the **Step 2 scoring + its embedded auto-fixes** (autonomy / testability /
  verification / trap) — a fix may legitimately apply again on the new state;
- the **per-modified-plan slice** of any finding-producing check that drove an
  edit on that plan: the seam-contract diff on the dependency edges incident to
  the modified plan (plan 028) and the adversarial audit of the modified plan
  (plan 027). These re-run only for the changed plan(s), re-confirming the
  finding that triggered the edit.

Do **NOT** re-run the whole-backlog passes: Step 2b learnings, Step 2c frame
review, and the full cross-plan consistency agent over untouched plans all run
once on the first pass and are not repeated here. Only the per-modified-plan
slices re-run, keeping the loop cheap.

### Bounded edit → re-validate loop (cap of 3 rounds)

Wrap the auto-fix phases and this re-validation in a loop:

1. Re-capture `PLAN_HASHES` (so the round sees only its own edits).
2. Run the auto-fix phases.
3. Recompute hashes; derive `MODIFIED_PLANS`.
4. If the round made **no edits** (`MODIFIED_PLANS` empty), stop — the backlog
   has converged.
5. Re-validate the modified plans (above). If re-validation applied further
   edits, repeat from step 1.

The loop stops when a round makes no edits **OR** after a hard **cap of 3
rounds**, whichever comes first. The cap prevents an oscillating fix/re-fix pair
from looping forever.

### Final-state gate: zero blocking findings

After the loop ends, evaluate the **FINAL file state** of each modified plan.
A modified plan is `ready`-eligible only if its final state has **zero blocking
findings**, where a blocking finding is any of:

- a structural **ERROR** (missing/invalid frontmatter, missing required section,
  no executable verification check);
- an unresolved **[critical]** frame-review finding;
- (once plans 027/028 land) a **GENUINE** adversarial-audit finding or a
  **blocking SEAM** finding.

This is an **absolute-count** gate: the test is "zero blocking findings on the
final state," NOT "no NEW errors versus the prior round." A pre-existing error
that was never fixed must NOT survive to `ready` just because the edit phase
didn't introduce it — if the final state still carries a blocking finding, the
plan is not ready.

If the loop hits the **cap of 3 rounds** with residual blocking findings, force
that plan's verdict to `needs-fixes`, list the residual findings, and
**forbid `ready`** — the plan is never silently marked ready when blocking
findings remain. Log the residuals so the human sees what is still unresolved.

### Logging

Log the re-validation distinctly so the human can confirm the loop ran:

```
Re-validated N modified plans: M clean, K need fixes
  043, "Redesign settings page": clean (round 2)
  045, "Fix scraper payloads": needs-fixes — residual ERROR: Verification has only [manual] checks (cap reached)
```

## Step 5: Run pending reviews

After validation, check which plans have `needs-review` set to something
other than `none` AND `status: blocked` (or `status: pending`, either way
they need review before the worker picks them up).

For each such plan, list it:

```
Plans pending review:
  042, "Add user avatars"           needs: ceo, eng, design
  045, "Redesign settings page"    needs: design
  048, "API rate limiting"         needs: eng
```

Then ask: **"Run pending reviews now?"**

If yes, for each plan in order:
- If `needs-review` includes `ceo`: invoke `/plan-ceo-review` (the gstack
  plan-ceo-review skill) **first**, since scope decisions should precede eng/design
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

### Re-validate review-edited plans

Reviews can edit a plan just as auto-fixes do, so the same loop applies. After
all reviews complete, recompute hashes once more and derive the set of plans a
review edited (hash differs from the `PLAN_HASHES` baseline). Re-validate each
review-edited plan with the same per-plan Step 4b procedure (Step 3 structural
validation + Step 2 scoring/auto-fixes + the per-modified-plan seam/audit
slices) BEFORE Step 6 finalizes that plan's verdict. A review-edited plan is
`ready`-eligible only on a clean final re-validation (zero blocking findings);
on residual blocking findings it is forced to `needs-fixes` — never silently
`ready`. Log the result in the same form: "Re-validated N modified plans:
M clean, K need fixes."

## Step 6: Summary

**Re-validation gate (applies to every modified plan).** A plan the doctor
edited — in the Step 4b auto-fix loop OR during Step 5 reviews — earns a `ready`
verdict ONLY if its FINAL re-validation was clean (zero blocking findings, per
Step 4b). A plan whose final re-validation still carries blocking findings is
reported `needs-fixes` with its residuals, never `ready`. An unmodified plan
(hash unchanged from the `PLAN_HASHES` baseline) keeps its first-pass verdict
unchanged — it was never edited, so there is nothing to re-validate. The
overall "ready for unattended execution" summary below is likewise gated: it may
declare the backlog clear only when every modified plan passed its final
re-validation.

Print a verdict that includes the review posture and score summary:

```
DOCTOR REPORT (posture: Hold)
=============================
Plans:  12 audited, 8 ready, 2 awaiting review, 1 needs fixes, 1 failed
Scores: avg 8.2/10, lowest 7.0/10 (plan 042, autonomy-readiness)
Auto-fixed: 3 plans (autonomy gaps filled from codebase analysis)
Trap resistance: 2 plans below 6/10 (warnings issued), 1 auto-fixed (was 3/10, now 8/10)
Learnings applied: 2 warnings surfaced from previous executions
Frame review: 12 plans reviewed, 5 critical findings, 8 advisory findings
  Auto-fixed frame findings: 3 (autonomy restored)
  Unresolved critical: 2 (flagged as user challenges)
```

**If no gaps, no errors, and no pending reviews:**
```
✅ Backlog is clear for unattended execution.
   Run: /goal all pending mstack plans are done or failed
```

**If gaps exist and posture blocks them (Expand/Selective):**
```
⚠️ N plans ready, but M coverage gaps would leave the feature incomplete.
   Run /mstack-plan-multi to fill gaps before running unattended.
   NOT ready for unattended execution.
```

**If gaps exist but posture doesn't block (Hold/Reduce):**
```
✅ N plans ready for unattended execution.
   Note: M coverage gaps identified (non-blocking in Hold/Reduce mode).
```

**If errors or pending reviews remain:**
```
⚠️ N plans ready, M awaiting review, K need fixes.
   Resolve before running /goal unattended.
```

**If any plan still scores below 5 on autonomy-readiness after auto-fix:**
```
🔴 Plan(s) below autonomy threshold (5/10), could not auto-fix:
   042, "Add user avatars" (autonomy: 4/10). Genuinely ambiguous decision.
   The architect must make this decision before walking away.
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

This section is informational; it doesn't block anything. It tells you
what shipped code still needs your eyes on it and what testing gaps remain
after pushing to remote.
