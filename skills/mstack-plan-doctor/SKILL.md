---
name: mstack-plan-doctor
description: |
  Validate plan files against mstack-plan-new / mstack-run format,
  find gaps, and run any pending reviews (eng, design, CEO). Accepts a specific
  plan id or file, or audits all plans in the plans directory. Uses sub-agents
  to parallelize deep validation across plans.
argument-hint: "[<plan-id|name|filename>]"
triggers:
  - validate plans
  - check plans
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

You are auditing plan files for compatibility with the `mstack-run`
autonomous worker. Optionally scope to a single plan; default is all plans.

User input (optional, a plan id like `042`, a name/slug fragment like
`my-feature`, a filename like `042-my-feature.md`, or blank for all):

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
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Enforcement-hook guard (plan 038)

Before validating the backlog, confirm the non-optional enforcement hook is
installed and current (`SKILL_DIR` from Auto-init points at `mstack-run`):

```bash
bash "$SKILL_DIR/scripts/review-gate.sh" assert-hook-installed
```

On a nonzero exit (`EXIT_GATE_HOOK_MISSING`, 26), the command printed the
problem (`core.hooksPath` unset, or a missing/stale hook) and the remedy.
Refuse to proceed and print the install command plainly:

```
[mstack] Enforcement hook missing or stale. Install it with `mstack-init`
(or `./setup` from the mstack source repo), then re-run /mstack-plan-doctor.
```

Do not run a plan-doctor validation pass against a repo whose write-time
barrier is absent — the whole point of doctor is to certify the backlog is
enforcement-ready.

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
  ID    Pri   Title                         Status                              Review    QA
  042   -     Add user avatars              ✅ done                             unreviewed  automated
  043   -     Redesign settings page        ✅ done                             ✓ reviewed  automated,e2e,browser
  044   -     API rate limiting             🔒 blocked (042: Add user avatars)  -           -
  045   1     Fix scraper payloads          ❌ failed                           -           -
  046   -     Migrate user table            🔄 in-progress                      -           -
  047   -     Add dark mode                 🚧 blocked: eng review required but not recorded  -  -
  048   -     Payment webhooks              ✅ done                             unreviewed  automated,e2e

Summary: 3 done (2 unreviewed, 1 without browser QA), 1 ready, 1 blocked, 1 failed, 1 in-progress, 1 gate open

Legend: ✅ done = shipped and verified · ready = the worker can pick it up now
· 🔒 blocked = waiting on the named dependency or prerequisite · ❌ failed =
attempted, gave up (frontmatter carries why + how to retry) · 🔄 in-progress =
mid-execution (stale if no session owns it) · 🚧 gate open = a required review
has no recorded verdict, so the worker will refuse to complete it
```

Always render the Legend line under the table. The emoji/status labels alone
assume the reader already knows mstack's lifecycle — the legend says what each
state means and what it implies for execution, so the dashboard is readable by
someone (or some future session) without that context. Keep each legend entry
to one plain-language clause; drop entries for states not present in the table
if space is tight, but never drop the legend entirely.

A `blocked` status cites its blocking dependency as `NNN: Title` (e.g.
`blocked (042: Add user avatars)`), not a bare id — build the citation from
the same single pass over plan files used to build this table (look the
dependency id up in the id→title map already assembled for the table rows,
rather than re-reading its plan file).

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

**Open-gate status (plan 036).** For every `pending`/`blocked` plan, don't
just read the mutable `needs-review` field for the status column — run
`review-gate.sh required <plan>` (from `mstack-run`'s `scripts/`) to get the
declared required set, then `review-gate.sh cleared <plan> <type>` for each
type in it. If any required type is not cleared, render the status as
`🚧 blocked: <type>[,<type>...] review required but not recorded` instead of
whatever `needs-review`-derived status would otherwise show, and count it
under "gate open" in the summary line rather than "awaiting review". This
independently confirms the same fail-closed state `mstack-run` Step 7a checks
via `assert-completable`, so a plan whose `needs-review` bookkeeping drifted
out of sync with `review-required`/`reviews` (e.g. a hand-edit) still shows
as blocked here rather than silently reading "ready". Only spawn these calls
for plans with a non-empty required set (skip the common case with nothing
declared) to keep this bounded — one pair of subprocess calls per flagged
plan, not a quadratic pass.

**Approved-but-uncommitted audit + heal (plan 037).** For every non-archived
plan (any status), cheap-prefilter first: does the plan carry any `reviews:`
entry at all? Skip plans with none (the common case — unreviewed /
authoring-only plans are exempt by design). For each plan that has >=1
recorded `reviews:` entry, run `review-gate.sh assert-committed <plan>`
(from `mstack-run`'s `scripts/`). This stays bounded — one subprocess per
flagged plan, not a pass over the whole backlog. If it exits nonzero,
surface it in the table/summary:

```
  047   -     Add dark mode                 ⚠️  approved but uncommitted     -           -
```

and list it separately:

```
Approved but uncommitted (heal these — commit the recorded approval):
  047: Add dark mode
```

After the dashboard, if any plans are listed here, ask: **"Commit these
approvals now?"** If yes, for each: `git add <plan-file>` then
`git commit -m "chore(plan <id>): approve (backfill)" -m "Refs: docs/plans/<plan-file-basename>"`
— explicit file list, no push. This heals pre-existing dirty approvals (not
just ones this run just recorded), since a crash, stash, or hand-edit could
have left one dirty in a prior session. If no, print the list and continue;
do not block the rest of the doctor run on it.

**Retroactive review audit (plan 038).** Run `review-gate.sh audit` once (from
`mstack-run`'s `scripts/`, resolved the same way as the other review-gate
calls) — a single bounded scan over all `done`/archived plans that flags any
whose `review-required` types lack a passing `reviews:` record. This is the
backstop for completions made with `git commit --no-verify` (which skips the
write-time hook) or by out-of-band edits; the write-time hook only sees commits
that actually run it. Surface any offenders:

```
Review audit (done/archived plans missing a required review record):
  047: Add dark mode — missing passing record for review 'eng'
```

The command is silent and exits 0 when clean. Healing an offender means running
the named review skill (`plan-eng-review` / `plan-design-review` /
`plan-ceo-review`, or `mstack-code-review` for a `code` gate) to record the
missing verdict — never hand-write a passing record. Report it; do not block
the rest of the doctor run on it.

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

If the user specified a plan, resolve it to a single file. First try a literal
match: an id prefix (`042`) or filename (`042-my-feature.md`). If that doesn't
match, treat the argument as a name/slug/title fragment and resolve it via the
plan-031 resolver (`resolve_plan_ref` in `mstack-run`'s `lib.sh`):

```bash
RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$RUN_SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
done
source "$RUN_SKILL_DIR/scripts/lib.sh"
ref_out="$(resolve_plan_ref "$ARGUMENTS")"; ref_rc=$?
```

Unlike `mstack-run`'s scope position (which takes free-form prose and needs
explicit delimiters to avoid guessing), `mstack-plan-doctor` takes a single
identifier argument — the whole `$ARGUMENTS` value IS the reference, so a bare
slug here is unambiguous and needs no quoting or `name:`/`plan:` prefix.

- `ref_rc` = 0: use the resolved id's file, regardless of `active`/`archived`
  status — plan-doctor is a read/validate tool, not an execution picker, so
  auditing an archived plan on request is fine.
- `ref_rc` = `EXIT_REF_AMBIGUOUS` (21): report the printed candidates (`NNN:
  Title` per line) and stop; do not guess.
- `ref_rc` = `EXIT_REF_NOT_FOUND` (22): report "plan '$ARGUMENTS' not found"
  and stop.

If no argument, collect all `*.md` files in `$PLANS_DIR`.

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
  to assert and how. Includes a `[browse]` check or an E2E-runner `[cmd]`
  check for web-facing plans.
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
application (`[cmd]` with a functional test, `[status]`, `[browse]`, or an
E2E-runner `[cmd]`) to score above 5.

**Web-facing testability error:**
If the plan touches web-facing files (detect from "Files expected to change":
`pages/`, `components/`, `routes/`, `templates/`, `*.tsx`, `*.vue`, `*.html`,
`*.css`, `*.svelte`, `app/`) AND has no `[browse]` check,
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
  - Testability: add a [browse] check, or an E2E-runner [cmd] check
    (playwright/cypress), that verifies the feature works in a browser,
    not just that files exist
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
> - `status`: one of pending, in-progress, done, failed, blocked, skipped.
>   `skipped` means the plan was deliberately retired (folded into another
>   plan, obsoleted, dropped) — `mstack-backlog` writes it. It is a legal
>   terminal status: never an error, and the picker never selects it. But a
>   skipped plan never becomes `done`, so any plan whose `blocked-by` names
>   it can never unblock — report that as its own diagnostic, `blocked-by
>   references skipped plan <id> — this plan can never unblock; drop the
>   dependency or skip this plan too`, not as a generic missing-dependency
>   error.
> - `blocked-by`: `[]` or list of ids
> - `priority`: integer (optional, defaults to id; used for execution ordering)
> - `allows-migrations`: true or false (warning if missing, defaults false)
> - `needs-review`: comma-separated combination of none, eng, design, ceo, code (warning if missing). `code` is written by `mstack-run` when a code-review gate is left open; it has no auto-runnable review skill (see Step 5).
> - `created`: YYYY-MM-DD (warning if missing)
> - `completed`: required if status=done (warning)
> - `reviewed`: required if status=done, `false` or `true` (warning if missing, defaults false)
> - `qa`: required if status=done, comma-separated: `none`, `automated`, `e2e`, `browser` (warning if missing, defaults none)
> - `verification`: optional, `health-only` to opt out of executable verification checks (warning if set)
> - `review`: optional, `thorough` for 3-reviewer pipeline (defaults to standard 1-reviewer)
> - `failed-reason` + `failed-at`: required if status=failed (warning)
>
> **Section structure** (error if missing):
> - `## Plain-English Summary` immediately after frontmatter. It must contain
>   a concrete, jargon-free description of the problem and expected outcome,
>   plus a `**What changes in the code:**` explanation in plain English. It
>   cannot be the template instructional text, a task list, or a file-path /
>   symbol dump.
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

## Step 3.5: Adversarial cross-model audit

The Step 3 sub-agents are same-model and are handed the plan's own framing, so
they tend to confirm the plan's narrative. This step breaks that monoculture:
when an external `codex` model is available, audit each plan against the **real
source** with a skeptical, falsify-first rubric, then fold genuine findings into
the report and the Step 4b re-validation set. It runs after structural
validation (Step 3) and before the report (Step 4).

### Discovery + provider gate (mirror mstack-code-review)

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-plan-doctor"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-plan-doctor" ] && SKILL_DIR="${_skill_base}/mstack-plan-doctor"
done
RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$RUN_SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
done

command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
# review.provider preference (auto | codex | gemini | claude-only); empty if unset.
PROVIDER="$(bash "$RUN_SKILL_DIR/scripts/config.sh" get review.provider 2>/dev/null || true)"
echo "REVIEW_PROVIDER: ${PROVIDER:-unset}"
```

Decide **run vs skip-with-note** from `review.provider` (mirroring how
`mstack-code-review` reads the same key) and codex availability:

- `codex`, or `auto`/unset **with the codex binary present** → **RUN** the audit.
- `claude-only` → SKIP. Log: "adversarial audit: review.provider=claude-only,
  skipping".
- `gemini` → SKIP (explicitly DEFERRED — out of scope for this step). Log:
  "adversarial audit: gemini not yet supported, skipping". Do NOT invent gemini
  behavior.
- No `codex` binary (any provider) → SKIP. Log: "adversarial audit: codex not
  available, skipping".

**A skip is never an error.** When skipped, note it in the Step 4 report
("Adversarial audit: skipped (<reason>)") and proceed straight to Step 4.

### Run the audit (per-plan codex-exec fan-out)

When the gate passes, load the full procedure and run it:

> **Read** `"$SKILL_DIR/references/adversarial-audit.md"` for the rubric, the
> literal `codex exec --sandbox read-only` command with its filesystem-boundary
> preamble, the per-plan prompt template, the finding output schema, the
> deterministic GENUINE-vs-FORWARD-DEPENDENCY classifier, the auto-fix-on-GENUINE
> procedure, the fault-tolerance rules, and the report-merge format.

Operate per the reference:

1. **Fan out** one read-only `codex exec` audit per validated plan, in parallel
   where the host supports concurrent Bash calls. Each call gets its own stderr
   tempfile, stdin from `/dev/null`, and a `timeout: 300000` (300s) on the Bash
   call.
2. **Fault tolerance:** on codex non-zero exit, timeout, empty/malformed output,
   or a finding missing its `file:line`, log that plan as **audit-inconclusive**,
   skip it, and let the other plans proceed. Never stall the backlog on one
   plan; never fabricate a finding.
3. **Classify** each well-formed finding deterministically: it is
   **FORWARD-DEPENDENCY** (noted, non-blocking) iff it references a
   file/symbol/endpoint that a NOT-yet-`done` `blocked-by` ancestor declares it
   will produce (that ancestor's "Files expected to change"/Design — or, once
   plan 028 lands, its `mstack:seam` produced block). Otherwise **GENUINE**
   (blocking).
4. **Auto-fix on GENUINE:** apply a plan edit that addresses the finding (same
   auto-fix discipline as the autonomy/verification fixes). The edit changes the
   plan's content hash, so it joins `MODIFIED_PLANS` — marking the plan MODIFIED
   so the Step 4b loop re-validates it AND the audit re-runs on the modified
   plan. If a GENUINE finding cannot be auto-resolved (genuine ambiguity),
   surface it as a blocking finding → force `needs-fixes`, never silently
   `ready`. The Step 4b 3-round cap bounds the fix↔audit cycle.
5. **Merge** the audit findings into the Step 4 report (an `AUDIT` line per
   finding, per the report-merge format), and feed every auto-fixed plan into
   the **Step 4b re-validation set** so its per-modified-plan audit slice
   re-runs on the new state.

### The premise-attack brief (Rule 4, plan 090)

The audit above breaks the same-model monoculture. It does not, by itself, break
the same-*mandate* monoculture: through plan 089 the outside voice was briefed to
do a sharper version of the primary reviewer's job, and on the cctrl 051-053
batch it did exactly that — "No tension — Codex sharpened two review findings
rather than disputing them" — while two P1 defects went out. Rule 4 changes what
the outside voice is pointed at. Gate it first:

```bash
if bash -c '. "$1/scripts/lib.sh"; rule_mode_line premise_brief' _ "$RUN_SKILL_DIR"; then
  PREMISE_BRIEF=on
else
  PREMISE_BRIEF=off
fi
```

- `PREMISE_BRIEF=on` — compose the premise-attack brief from the reference:
  **do not sharpen or extend the primary reviewer's findings**; attack premises
  in the order (a) the plan's uncited factual claims, (b) every "should /
  presumably / by construction / obviously" sentence, (c) any premise whose
  failure invalidates a whole acceptance criterion. Inject Step 3.9's `UNCITED`
  lines for that plan as the `UNCITED PREMISES (attack these first):` section,
  and **omit the section entirely — heading included — when the lint produced
  no `UNCITED` lines or Rule 1 is disabled.** Never send it empty and never send
  "none found": that reads as a clearance the lint never gave.
- `PREMISE_BRIEF=off` — send the **pre-090 falsify-first brief** kept verbatim
  under "Fallback brief" in the reference, send no `UNCITED PREMISES` section,
  and **skip the no-tension trigger below**. Log:
  `adversarial audit: rule premise_brief disabled — using the pre-090
  falsify-first brief, no premise pass`.

Nothing else moves. The sandbox flags, the `mktemp` template, `< /dev/null`,
`2>"$TMPERR"`, the 300s timeout, the `FINDING:` schema, the
GENUINE/FORWARD-DEPENDENCY classifier, and the fault-tolerance rules are
unchanged by Rule 4 — the mandate is the cheap part of this rule and rewriting
the machinery would price it like the expensive part.

### The no-tension trigger (once per doctor run)

**A unanimous clearance is evidence about the brief, not about the plans.** When
the audit comes back empty across a *batch*, the likeliest explanation is not
that several plans are simultaneously flawless; it is that the outside voice was
reading with the same attention as the primary one. So unanimity buys one more
pass, not a verdict.

Fire the trigger when ALL of these hold:

1. `PREMISE_BRIEF=on`.
2. The audit was **CONCLUSIVE and returned zero findings on two or more plans**
   in this run. **An `audit-inconclusive` plan is not a clean plan**: it
   contributes no findings by design (see the reference's fault-tolerance
   rules), so counting it as clean would let a codex timeout manufacture the very
   unanimity this trigger exists to distrust. An inconclusive plan counts toward
   neither `N` nor the premise pass's scope.
3. The trigger has **not already fired in this doctor run**. It fires at most
   ONCE — it is a smell check, not a loop. A per-plan version would fire on every
   clean single-plan run and turn the check into a tax; an unbounded version
   would never terminate.

Then run **exactly one** additional `codex exec` pass, same invocation
mechanics, scoped to premises only, over **the conclusive-and-clean plans
only**. Report its findings as `AUDIT [PREMISE-PASS]` rows (report-merge format
in the reference); they classify and block exactly like any other audit finding.

#### The canonical log line — one format, always both counts

"No tension" names the **audit channel only**. The Step 3 validators' findings
are merged separately ("Collecting results" above) and may be non-empty while
codex returns nothing — a different state from "everything is clean", and
collapsing the two is how a reader gets told two channels agreed when only one
was silent. So there is exactly ONE format, and it carries both counts. The
trigger, the waiver, and the report row all use it:

```
CROSS-MODEL: no tension — codex clean on N/N conclusive plans, primary validation raised M findings — <running one premise-directed pass | premise pass WAIVED (<reason>)>
```

- `N/N` counts **conclusive** plans only; inconclusive plans are named
  separately on their existing `audit-inconclusive` line and never inflate `N`.
- `M` is the Step 3 validator finding count for the same run. The trigger keys
  on the codex count; `M` is printed so the reader can see when the two channels
  did *not* agree.
- The line closes with exactly one of its two arms. **Running arm:** the premise
  pass ran, and its `AUDIT [PREMISE-PASS]` rows follow (including zero rows,
  stated as such). **Waiver arm:** the architect declined the extra pass, and the
  reason is recorded in the line. A "no tension" line with neither a premise-pass
  result nor a recorded waiver is **not a legal report state** — silence there
  would restore exactly the false clearance this rule exists to remove.

## Step 3.6: Seam-contract verification (dependency-edge interface check)

Step 3's cross-plan consistency agent checks dependency ORDERING and file
overlap, but not interface CONSISTENCY: whether a plan's assumptions about the
artifacts its `blocked-by` ancestors PRODUCE actually match what those ancestors
PROMISE (a function signature, a record shape, an endpoint verb+path, a CLI
flag, a file). This step adds that seam-contract check. It runs after structural
validation (Step 3) and the adversarial audit (Step 3.5), and before the report
(Step 4).

**Scope — runs in BOTH all-plans and single-plan scope.** Unlike the cross-plan
consistency agent (all-plans only), the seam check must NOT be confined to that
agent: plan 029's recovery path sends users to single-plan doctor
(`/mstack-plan-doctor NNN`), so the seam check must actually run there too. In
all-plans scope it diffs every `blocked-by` edge in the backlog; in single-plan
scope it loads NNN's `blocked-by` ancestors and checks only the edges incident
to NNN.

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-plan-doctor"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-plan-doctor" ] && SKILL_DIR="${_skill_base}/mstack-plan-doctor"
done
```

> **Read** `"$SKILL_DIR/references/seam-contracts.md"` for the canonical
> `<!-- mstack:seam ... -->` block grammar (delimiters, field order, quoting,
> and the byte-identical idempotent-emission algorithm), the heuristic
> PRODUCED/ASSUMED extraction rules, attribution + normalization, the name-first
> + shallow-shape edge diff, the `file:`-anchored verifiability rule, the
> MISSING / SHAPE-DIVERGENT / UNVERIFIABLE taxonomy and which findings block the
> `ready` verdict, and the SEAM report format. That reference is the single
> source of truth plan 029 also obeys — keep this step consistent with it.

Operate per the reference:

1. **Extract** the PRODUCED and ASSUMED contract sets per plan (heuristic, from
   the plan's `**Files expected to change:**` + Design/Tasks prose). Attribute
   each ASSUMED entry to a single `blocked-by` ancestor (`from:` id).
2. **Emit** the normalized `<!-- mstack:seam ... -->` block into each plan file
   IDEMPOTENTLY. The fixed field order (`from, kind, name, shape, file`) +
   `LC_ALL=C` entry sorting + canonical whitespace make a no-op re-emit
   BYTE-IDENTICAL, so re-emitting an unchanged contract does NOT change the
   plan's content hash and does NOT mark the plan modified (no spurious churn in
   plan 026's Step 4b loop).
3. **Diff** each `blocked-by` edge A→B: B.ASSUMED-from-A vs A.PRODUCED, name-first
   then shallow-shape (shape compared only where BOTH sides state one). Anchor
   verifiability on `file:` exactly as the reference defines: an assumed entry
   with a `file:` is VERIFIABLE (existence + in-file shape token); an assumed
   entry with no `file:` is UNVERIFIABLE — noted, never MISSING, never grepped
   repo-wide. Per the reference, copy the producer's `file:` into a resolved
   assumed entry to maximize downstream verifiability.
4. **Classify** each finding: MISSING and SHAPE-DIVERGENT are BLOCKING (they gate
   the `ready` verdict — a blocking SEAM finding in plan 026's Step 4b/Step 6
   blocking set); UNVERIFIABLE is noted only.
5. **Report** SEAM findings in the Step 4 report (below), and feed every
   seam-triggered plan edit into the **Step 4b re-validation set** — the edit
   changes the plan's content hash, so plan 026's loop re-runs the seam diff on
   that plan's incident edges.

Leave the existing ordering/overlap checks in the cross-plan consistency agent
unchanged — the seam check is additive.

## Step 3.7: Probe the verification checks (deterministic — plan 046)

Everything above tests that verification checks EXIST. Existence is not
workability. A plan can declare `--dry-run` on a flag the CLI does not have,
`pytest -m browser` that collects zero tests, or `test -f` on a path nothing
creates — each passes an existence check while being dead on arrival, and the
worker only finds out after implementing. Run the probe, per plan:

```bash
bash "$RUN_SKILL_DIR/scripts/verify-lint.sh" probe <plan>
```

It executes only the checks it can PROVE are read-only (every command head on
an allowlist, no redirects, no substitution into unknown binaries) and reports:

- **BROKEN** — the check provably cannot work, no matter what the worker does:
  its command head does not exist (exit 127/126), or it targets a path that is
  absent AND that the plan never declares it will create. Exit
  `EXIT_VERIFY_BROKEN` (33). Treat as a **blocking finding** for the Step 4b
  gate, same class as a structural ERROR: the plan's own test oracle is dead,
  so the worker would "verify" nothing. Fix the check, do not delete it.
- **PENDING** — the check RUNS, its targets exist, and it does not pass yet.
  **Reported, never blocking.** This is the expected state for a post-condition
  on unimplemented work: `grep -q "EXIT_GOAL_NOT_FOUND" README.md`, for a plan
  whose job is to ADD that row, is SUPPOSED to fail now and pass after. Do NOT
  "simplify" PENDING into BROKEN — that conflation blocked every plan that
  verifies its own output, and the tell was that only plans whose code had
  already shipped ever probed clean. Same calibration as Step 3.8's PENDING
  below, and it is load-bearing for the same reason.
- **SUSPECT** — a CLI flag the check passes appears nowhere in the repo.
  Heuristic (the flag may be added by this very plan), so report it, do not
  block. Confirm against the plan's Design before dismissing.
- **UNPROBED** — could not be proven safe to execute (e.g. `python manage.py
  …`; executing project code is a different risk class). **Report it as
  not-verified. It is NOT a pass** — reading silence here as approval rebuilds
  exactly the defect this step exists to catch.
- **OK** / **SKIP** — probed and working / `[manual]`+`[browse]`+`[status]`,
  not executable at authoring time.

The probe answers "would this check work?", never "did the feature work" —
that stays `mstack-run` Step 5b, after implementation. It is safe to run on any
plan at any time because it never writes.

## Step 3.8: Does the health gate actually run this plan's tests? (plan 047)

Step 3.7 asks whether the plan's own checks can work. This asks the adjacent
question nothing else covers: **if the plan declares it adds a test file, does
the configured health-gate command actually execute that file?**

```bash
bash "$RUN_SKILL_DIR/scripts/health-reach.sh" reach <plan>
```

The observed escape: a `.mstack/config.json` test command carried a `-k` filter
that excluded `test_curl_cffi_impersonation_guard.py` entirely. The gate ran,
reported green, and covered none of the new code. Plan 043 fixed the zero-tools
case; this is the sibling where tools are detected, the command runs, and its
selector excludes the code under test.

Four states, and the calibration matters more than the detection:

- **UNREACHABLE** — the file EXISTS and the gate command does not collect it. A
  proven defect: **blocking** (exit 34). The finding names the file and the
  excluding command. Fix the command or the plan, never by deleting the test.
- **PENDING** — declared but not created yet. **Reported, never blocking.** A
  plan legitimately declares tests it has not written; blocking here would fail
  every plan before implementation.
- **UNKNOWN** — runner unrecognized (pytest and jest are supported) or no test
  command resolvable. **Reported as NOT VERIFIED, never as covered, and not
  blocking** — blocking every non-pytest repo is how a check earns a permanent
  bypass, and a bypassed check covers nothing.
- **REACHABLE** — file exists and is collected.

Do not "simplify" PENDING or UNKNOWN into blocking states. That over-block was
shipped once in `verify-lint.sh` and flagged six well-formed plans as broken;
the calibration is deliberate and load-bearing.

## Step 3.9: Citation-or-finding lint (deterministic — plan 088, Rule 1)

Steps 3.7 and 3.8 ask whether a plan's checks can work. This asks the question
nothing else in the pipeline asks: **does the plan cite the code it depends
on?**

```bash
bash "$RUN_SKILL_DIR/scripts/premise-lint.sh" lint <plan>
```

The escape it targets: the pipeline verifies what a plan CITES and exempts what
it ASSERTS. In the cctrl 051-053 batch two P1 defects cleared an eng review AND
a cross-model pass; both were the batch's only uncited premises about existing
code, while every cited claim in the same plans had been checked. Decorating a
claim with a citation attracted verification; omitting one bought exemption.

The script prints its mode line first (`[mstack] rule citation_or_finding:
enabled|disabled (config)`) and then one line per acceptance criterion:

- **CITED-UNRESOLVED** — the AC cites a `snake_case`/`camelCase` symbol or a
  repo-relative path that resolves nowhere in the working tree AND that no plan
  declares it will create. Provable from the repo, so it is **blocking**, exit
  `EXIT_PREMISE_UNCITED` (37). Same class as a structural ERROR for the Step 4b
  gate. Fix by citing the real identifier, never by deleting the citation.
- **UNCITED** — the AC carries a premise signal about existing code (`should`,
  `presumably`, `assumes`, `already`, `existing`, `since`, `because`, …) and
  cites nothing. **The script never blocks on this**; the doctor does, below.
- **CITED-OK** — every citation resolves, or is a declared forward reference
  (this plan's own `**Files expected to change:**`, or a not-yet-`done`
  `blocked-by` ancestor's).
- **NO-PREMISE** — the AC asserts nothing about existing code.

The split is by whether the class is PROVABLE, and it is the same calibration
Steps 3.7/3.8 use for PENDING/UNKNOWN. CITED-UNRESOLVED is provable and blocks
in the script. UNCITED is a word-list match over prose that both over- and
under-matches, so the deterministic layer reports it and the judgment happens
here. Do not "simplify" UNCITED into a script-level block.

Disable with `config.sh set rules.citation_or_finding false`. That toggle
disables Rule 1 and nothing else; every other state — absent config, unreadable
config, no `rules` object — means ENABLED.

## Step 3.10: Fixture-as-artifact lint (deterministic — plan 089, Rule 3)

Step 3.9 asks whether a plan cites the code it depends on. This asks the same
question about a surface no citation can reach: **a plan whose logic keys on
terminal screen content must attach a real capture of that screen.**

```bash
bash "$RUN_SKILL_DIR/scripts/fixture-lint.sh" lint <plan>
```

Pane-scraping is an integration against an undocumented, unversioned external
interface. Nobody writes a parser for a third-party API from memory — they save
a real response and code against it, and the capture is that saved response.
Every shipped cctrl detector bug (ASCII `>` vs the real prompt glyph, an "Allow
command" string matching no real modal, the 2026-08-05 picker premise) lived in
the gap between what an author *remembered* a screen saying and what it says.

The script prints its mode line first (`[mstack] rule tui_fixture:
enabled|disabled (config)`) and then exactly ONE verdict line whose first
whitespace-delimited token is one of exactly four verdicts. Everything after
that token is human-readable detail; consumers parse token one and ignore the
rest, so richer detail can never introduce a fifth verdict.

- **FIXTURE-MISSING** — the plan's Requirements/Design/Tasks prose matches the
  pane vocabulary (below) and either declares no capture under a `fixtures/`
  path, or declares one that is not in the working tree. **Blocking**, exit
  `EXIT_TUI_FIXTURE_MISSING` (38). Same class as a structural ERROR for the
  Step 4b gate.
- **FIXTURE-UNDATED** — the declared capture exists but its `<fixture>.meta`
  sidecar is missing or incomplete. **Reported, never blocking.**
- **FIXTURE-OK** — the capture exists and carries provenance.
- **NOT-APPLICABLE** — no pane vocabulary, or the plan carries the declared
  exemption. The overwhelmingly common case; it still prints its verdict line,
  because a silent run is indistinguishable from a lint that never ran.

**The calibration deliberately departs from Steps 3.7/3.8, and the departure is
the point.** Those defer (PENDING) on a plan's *output* — a check or test file
it has not written yet — because blocking pre-implementation work is how a lint
earns a permanent bypass. A capture is an *input*: evidence the author had to
hold before writing the detector. Rule 3's text is "must attach", present tense.
A plan promising to capture the screen later is precisely the plan that writes
its detector from memory first. Do **not** "simplify" the declared-but-absent
case into a PENDING-shaped report by analogy with 3.7/3.8; the analogy is what
is wrong.

**The vocabulary is two-tiered.** STRONG keywords name the *mechanism* of
reading a screen — `capture-pane`, `send-keys`, `tmux`, `pane shows`, `pane
content`, `screen scrape`, `screen-scrape` — and each matches on its own. WEAK
keywords name a screen *artifact* — `modal`, `picker` — and match only when a
STRONG keyword is also present. Measured, not guessed: the un-tiered list fired
on 9 of 41 live plans in the mstack repo and every one was a false positive
("picker" there means `pick-next.sh`). Real pane work loses nothing, because a
plan that scrapes a pane must say how it reads the pane.

**Dismissing a false positive still costs only a glance, by design.** The
finding names the matched keyword and quotes the matching line, because a
keyword list can still over-match (a plan that discusses `tmux` without scraping
anything). When the match is incidental, the fix is a one-line frontmatter
declaration in the plan, which review can read:

```yaml
tui-fixture: n/a  # <why this plan scrapes no pane>
```

The reason is REQUIRED — a bare `tui-fixture: n/a` is not honored and the plan
is linted normally. Same block-unless-declared doctrine as the health gate's
`- none:` entry: explicit, in the tracked plan file, never derivable from
gitignored local state.

Disable with `config.sh set rules.tui_fixture false`. That toggle disables Rule
3 and nothing else.

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
  SEAM    [SHAPE-DIVERGENT] 042 assumes symbol `gate` from 026: Re-validate plans after auto-fix and review edits (close the doctor loop) | assumed `gate(plan)` vs produced `gate(plan, ctx)`: arg count 1≠2 (blocking)
  SEAM    [UNVERIFIABLE] 042 assumes endpoint `POST /dispatch/confirm` from 031: Shared plan-reference resolver library (id <-> title <-> name) | no file: anchor (noted)
  PREMISE [CITED-UNRESOLVED] AC3 cites `resolve_avatar_url` — resolves nowhere in the working tree and no plan declares it (blocking)
  PREMISE [UNCITED] AC5 premise signal "should" with no citation — add the citation or rewrite the AC (blocking unless resolved)
  FIXTURE [FIXTURE-MISSING] pane-dependent (keyword "picker") but no capture is declared under a fixtures/ path | "when the picker is on screen, pause the runner" (blocking)
  AUDIT   [PREMISE-PASS] app/models/upload.rb:14 AC4 assumes uploads are already virus-scanned; no scanner is wired (blocking)
  AMEND   [p2 audit-genuine] round 2 — re-checked: yes (codex), 0 defects
  AMEND   [p2 review-edit] round 3 — re-checked: no (blocking)

Cross-plan: [1 warning]
  WARNING plans 043 and 045 both modify src/components/Settings.tsx with no dependency

CROSS-MODEL: no tension — codex clean on 5/5 conclusive plans, primary validation raised 3 findings — running one premise-directed pass
```

The `CROSS-MODEL:` line and any `AUDIT [PREMISE-PASS]` rows come from Step 3.5's
no-tension trigger. The line appears once per doctor run, never per plan, and
always in the canonical format above — both counts, and one of its two closing
arms. It is omitted entirely when the trigger did not fire (the audit found
something, fewer than two plans were conclusive-and-clean, or
`rules.premise_brief` is disabled); it is never printed with the arm left off.

The `PREMISE` lines come from Step 3.9. `[CITED-UNRESOLVED]` is blocking in the
script itself (exit 37); `[UNCITED]` is reported by the script and made blocking
by the Step 4b gate below, unless it was resolved in an auto-fix round. Both name
the AC index and, for CITED-UNRESOLVED, the identifier that did not resolve —
without the identifier the finding is unactionable. When a `PREMISE` line names
another plan, render it `NNN: Title` per the plan citation convention.

The `FIXTURE` lines come from Step 3.10, one per plan, carrying the script's
verdict token verbatim. Only `[FIXTURE-MISSING]` is blocking;
`[FIXTURE-UNDATED]` is noted. `[FIXTURE-OK]` and `[NOT-APPLICABLE]` need no row
at all — print one only when there is something to act on, so the common case
adds no noise to the report. The row must carry the matched keyword and the
quoted line, because without them the architect cannot tell a real pane
dependency from an incidental mention of `tmux`, and an undismissable finding is
one that gets the whole rule switched off. When a
`FIXTURE` line names another plan, render it `NNN: Title` per the plan citation
convention.

The `AMEND` lines come from Step 4b's amendment capture (plan 091, Rule 2) —
one row per amended plan per round, printed only for plans the doctor actually
edited. The row carries the stored severity and trigger, the round, and whether
the re-pass ran and who ran it: `re-checked: yes (codex|same-model), N defects`
or `re-checked: no`. A `no` on a P2-or-above amendment is **blocking** and is
what Step 6's `assert-rechecked` gate refuses `ready` for; a P3 amendment
prints its row and never blocks. Omit the rows entirely when
`rules.amendment_repass` is disabled — an absent row is honest there, a
`re-checked: no` row would read as a finding the doctor did not make. When an
`AMEND` line names another plan, render it `NNN: Title` per the plan citation
convention.

The `SEAM` lines come from Step 3.6. `[MISSING]` and `[SHAPE-DIVERGENT]` are
BLOCKING (they gate the `ready` verdict per the Step 4b/Step 6 blocking set);
`[UNVERIFIABLE]` is noted only. The line cites the audited plan's bare id
(its title already appears in this block's header above) but spells out
the `from` plan as `NNN: Title`, since that plan's title is not otherwise
on screen, plus the symbol/endpoint + the mismatch type so the architect
can confirm or override.

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
- the **Step 3.9 citation lint** (`premise-lint.sh lint <plan>`) for the
  modified plan. This one re-runs because the edit phases rewrite acceptance
  criteria: a fix that adds a citation must be re-checked (the newly named
  identifier may itself not resolve), and a fix that rewrites an AC can
  introduce a fresh uncited premise. Without the re-run, "the doctor added a
  citation" would be taken on trust — which is the whole class of defect Rule 2
  names, appearing inside the tool meant to catch Rule 1's.
- the **Step 3.10 fixture lint** (`fixture-lint.sh lint <plan>`) for the
  modified plan. The edit phases rewrite Requirements, Design, and Tasks — the
  exact prose the pane vocabulary is matched against — so a fix that sharpens an
  AC into "when the pane shows the approval modal, pause" turns a
  `NOT-APPLICABLE` plan into a `FIXTURE-MISSING` one mid-loop. Without the
  re-run the Step 4b final-state gate would pass on a stale first-pass verdict,
  which is the same take-it-on-trust defect the citation re-run above exists to
  prevent.

Do **NOT** re-run the whole-backlog passes: Step 2b learnings, Step 2c frame
review, and the full cross-plan consistency agent over untouched plans all run
once on the first pass and are not repeated here. Only the per-modified-plan
slices re-run, keeping the loop cheap.

### Capture every amendment before you make it (plan 091, Rule 2)

Everything above re-validates the plan **structurally**. What it never does is
look at the *amendment itself* with the one question that catches this class:
**assume this fix introduced a new defect; find it.** One of the two P1s in the
cctrl 051-053 batch was not in the original plan — the eng review *created* it,
correctly replacing a too-loose readiness form with an allow-list that turns out
to be unsatisfiable. The highest-churn text in this pipeline is the text reviews
write, and it is the only text nothing reviews.

Gate the whole of this on Rule 2's toggle, and say which mode is in play:

```bash
bash -c '. "$1/scripts/lib.sh"; rule_mode_line amendment_repass' _ "$RUN_SKILL_DIR" || true
```

With `rules.amendment_repass=false`, skip capture and the re-pass entirely and
do not consult `assert-rechecked` in Step 6. Rules 1, 3 and 4 are unaffected by
that key.

**The capture sites are enumerated, not implied.** Today's auto-fix phases emit
free-text logs, not typed events, and Step 4b knows only that a plan's hash
changed — which finding drove the edit, and how severe it was, is information
this step holds at edit time and immediately discards. So the severity and
trigger are *arguments*, and every site that transforms a plan calls `capture`
**immediately before applying the fix**, while the pre-edit file is still on
disk:

```bash
bash "$RUN_SKILL_DIR/scripts/amendment-repass.sh" capture <plan> <round> <severity> <trigger>
```

| Capture site | Severity | Trigger |
|---|---|---|
| GENUINE adversarial-audit finding auto-fixed (Step 3.5) | `p2` | `audit-genuine` |
| Blocking SEAM fix — MISSING / SHAPE-DIVERGENT (Step 3.6) | `p2` | `seam-blocking` |
| `[critical]` frame-review finding fixed (Step 2c) | `p2` | `frame-critical` |
| A review skill edited the plan (Step 5 — see below) | `p2` | `review-edit` |
| Autonomy-readiness auto-fix (Step 2) | `p3` | `autofix-autonomy` |
| Verification / testability auto-fix (Step 2) | `p3` | `autofix-verification` |
| Trap-resistance auto-fix (Step 2) | `p3` | `autofix-trap` |
| Mechanical-error auto-fix (Step 4) | `p3` | `autofix-mechanical` |

`<round>` is the Step 4b loop round the edit happens in (1, 2, 3). **A P3 site
escalates to `p2` when the finding that triggered it was itself P2 or above** —
a mechanical fix applied in service of a GENUINE audit finding is not a
mechanical amendment.

All four arguments are REQUIRED; there is no short form. A capture with fewer
than four arguments exits nonzero and writes nothing, on purpose: a silently
defaulted severity is how the classification signal would rot back to absent
while the records still looked complete. An *unrecognized* severity token is
tolerated and stored as `p2`, because unknown means "needs the re-check", never
"skip it".

The records live in `.mstack/amendments/plan-<id>.jsonl` with pre-images at
`.mstack/amendments/plan-<id>-r<N>.pre`. `.mstack/` is gitignored, so **this
record is local and non-authoritative by construction** — per-checkout working
state, invisible to review, absent on a fresh clone. It is the same caveat the
`.mstack/reviews/*.json` cache carries, and it is deliberately not frontmatter:
an amendment record is not a review verdict and must never become one.

### The scoped re-pass (one bounded pass, over the diff only)

Still **inside the bounded loop**: after an edit round produces
`MODIFIED_PLANS`, for each modified plan carrying a P2-or-above amendment from
this round, run exactly one focused adversarial pass.

The reviewer is given **the `amendment-repass.sh diff` output and the plan's
acceptance criteria — nothing else**:

```bash
bash "$RUN_SKILL_DIR/scripts/amendment-repass.sh" diff <plan> <round>
```

**Scope is what keeps this bounded.** A re-pass that re-reads the whole plan is
just a second full review under a different name, and the ~15-minutes-per-batch
price this rule was adopted at holds only while the input stays the diff.

The brief is one sentence: **"assume this fix introduced a new defect; find
it."** Route it through the outside voice (codex) when available, using plan
090's premise-attack framing from
`references/adversarial-audit.md` — the amendment's premises are the target,
not its wording — and run it as a same-model pass when codex is not available.
Record the result either way:

```bash
bash "$RUN_SKILL_DIR/scripts/amendment-repass.sh" record <plan> <round> <severity> <trigger> <by> <defect-count>
```

`<by>` is `codex` or `same-model`. `record` refuses a round with no matching
capture, so a mis-numbered round is a hard error rather than a false clearance.

**A defect the re-pass finds is handled exactly like a GENUINE audit finding:**
auto-fix it if unambiguous — which produces a *new* amendment, captured and
re-checked in the next round — otherwise surface it as blocking and force
`needs-fixes`. The existing 3-round cap bounds this; the re-pass adds no new
loop.

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
  **blocking SEAM** finding — a SEAM `MISSING` or `SHAPE-DIVERGENT` (Step 3.6);
  a SEAM `UNVERIFIABLE` is noted only and does NOT block.
- a **PREMISE** finding from Step 3.9 that is still open on the final state:
  `CITED-UNRESOLVED` (already blocking in the script, exit 37), and
  **`UNCITED` unless resolved**. Resolving an `UNCITED` means one of exactly
  two things: locate the real function or file and rewrite the AC to name it,
  or rewrite the AC so it no longer asserts anything about existing code.
  Deleting the signal word without doing either is not a resolution. An
  `UNCITED` that survives the round cap forces `needs-fixes` and forbids
  `ready`, exactly as an unresolved GENUINE audit finding does — a plan is
  never silently `ready` with a load-bearing uncited premise, because that is
  precisely how the two cctrl P1s cleared two reviews.
- a **FIXTURE** finding from Step 3.10 that is still open on the final state:
  `FIXTURE-MISSING` (already blocking in the script, exit 38), whether the cause
  is no declared capture or one declared and absent. `FIXTURE-UNDATED` is noted
  and does **not** block. Resolving a `FIXTURE-MISSING` means one of exactly
  two things: attach the real capture (and reference it from the plan's file
  list or a Verification grep), or add the `tui-fixture: n/a  # <reason>`
  declaration because the keyword match is incidental. Deleting the keyword from
  the prose is not a resolution — it hides the pane dependency instead of
  evidencing it.

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

Resolve `RUN_SKILL_DIR` once, before running any reviews:

```bash
RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$RUN_SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
done
```

### Review-invocation context block

Every review invocation below passes the same context block, not just a file
path. The gstack review skills live outside this repo and are NOT edited here —
**the wiring IS the context mstack passes in.** Compose it verbatim and hand it
to the review skill along with the plan file:

```
Plan file: <absolute path to the plan file>

Citation checklist (mstack Rule 1, plan 088): verify every cited premise
against the cited code; file every uncited load-bearing premise as a finding.

Step 3.9 premise-lint output for this plan:
<paste the premise-lint.sh lint output, or "clean" if it had no findings>

Premise-attack mandate (mstack Rule 4, plan 090): attack the plan's premises
before its details; a premise whose failure invalidates a whole AC outranks any
number of detail findings.
```

The checklist line is the whole point of Rule 1 at review time: it costs no
extra round, it redirects attention rather than adding it, and it names the
asymmetry the reviewers were falling into — verifying what the plan cited and
exempting what it asserted. Pasting the Step 3.9 output alongside gives the
reviewer the machine's list of uncited ACs to start from, so "uncited premise"
is a worklist, not a memory exercise.

The mandate line is Rule 4's cheapest surface: the gstack review skills are the
one channel in this pipeline that reads a plan with a human in the loop, and
telling them where to aim costs nothing per run. It is the same aim the Step 3.5
outside voice is given, so the two channels attack the same thing rather than
one polishing what the other cleared. Keep this ONE block — two competing briefs
in one invocation is worse than either brief alone.

Gate the mandate line on Rule 4's toggle, and say which brief is in play:

```bash
bash -c '. "$1/scripts/lib.sh"; rule_mode_line premise_brief' _ "$RUN_SKILL_DIR" || true
```

With `rules.premise_brief=false`, drop the mandate line and pass the **pre-090
context block** — the plan file path plus the Rule 1 citation checklist and
premise-lint output, exactly as plan 088 defined it — noting
`review context: rule premise_brief disabled — pre-090 block, no premise
mandate`. Rule 1's two lines are unaffected by that key.

### Capture AROUND the review invocation, not at a fix site (plan 091, Rule 2)

Reviews edit plans, and a reviewer's edit is exactly the class of amendment
Rule 2 exists for — the cctrl P1 that shipped was *created* by an eng review's
own fix. But there is no fix site to instrument here: the plan edit comes from
the review skill itself, which mstack does not own. So the capture brackets the
invocation.

For each plan about to be reviewed, **before invoking the review skill**:

```bash
bash "$RUN_SKILL_DIR/scripts/amendment-repass.sh" capture <plan> <round> p2 review-edit
```

Use the next unused round number for that plan. After the review returns,
recompute the plan's hash:

- **Hash changed — an amendment happened.** Run the scoped re-pass over
  `amendment-repass.sh diff <plan> <round>` exactly as Step 4b does, then
  `record <plan> <round> p2 review-edit <codex|same-model> <defect-count>`.
- **Hash unchanged — the review edited nothing.** There is no diff to attack, so
  spending a bounded call on an empty input buys nothing. Close the round
  immediately instead: `record <plan> <round> p2 review-edit unchanged 0`.
  **Closing it is not optional** — a `p2` capture left open blocks `ready`
  forever at Step 6, which would make "the reviewer changed nothing" indelibly
  indistinguishable from "the reviewer's change was never examined". The
  `unchanged` marker keeps the two legible in the ledger.

**Do NOT wire capture into the `changes-requested` bookkeeping branch below.**
That branch records a verdict and applies no fix; there is nothing there to
capture, and instrumenting it would manufacture amendments out of verdicts.

If yes, for each plan in order:
- If `needs-review` includes `ceo`: invoke `/plan-ceo-review` (the gstack
  plan-ceo-review skill) **first**, since scope decisions should precede eng/design
  review. Pass the review-invocation context block above.
- If `needs-review` includes `eng`: invoke `/plan-eng-review` (the gstack
  plan-eng-review skill). Pass the review-invocation context block above.
- If `needs-review` includes `design`: invoke `/plan-design-review` (the
  gstack plan-design-review skill). Pass the review-invocation context block
  above.
- If `needs-review` includes `code`: **not auto-runnable.** A `code` gate
  comes from an unresolved critical/high finding in `mstack-run` Step 6 and
  has no plan-stage review skill to invoke. Do not clear the tag and do not
  change `status`. Print, mirroring `mstack-run`'s own wording:
  `<id>: <title> — code gate open. Re-run /mstack-code-review (or fix the
  finding and re-record a passing verdict) — never self-clear the gate or
  hand-write a passing record.` Then continue to the next plan.
- After each review completes, if the reviewer approves:
  1. Record the verdict — this is the **authoritative** clear the gate reads.
     Run `review-gate.sh record <plan> <type> approved` (`<type>` is
     whichever of `eng`/`design`/`ceo` just ran):
     `bash "$RUN_SKILL_DIR/scripts/review-gate.sh" record <plan> <type> approved`.
     After this, `review-gate.sh cleared <plan> <type>` exits 0.
  2. Remove that reviewer's tag from `needs-review` (e.g., `ceo,eng` → `eng`)
     as bookkeeping only, kept for picker compatibility. When all tags are
     cleared, set `needs-review: none` and if `status: blocked`, change to
     `status: pending` so the worker can pick it up.
  3. **Commit the approval now (plan 037 — "approved ⇒ committed"
     invariant).** The plan file just gained a recorded `reviews:` verdict
     (and possibly a `needs-review`/`status` edit from step 2); per
     `AGENTS.md` an approved plan must never sit uncommitted. Commit only
     the plan file, by explicit file list, no push:
     ```bash
     git add "<plan-file>"
     git commit -m "chore(plan <id>): approve (<type>)" -m "Refs: docs/plans/<plan-file-basename>"
     ```
     After this, `review-gate.sh assert-committed <plan>` exits 0.
- If the reviewer requests changes:
  1. Record the verdict. Run `review-gate.sh record <plan> <type> changes-requested`:
     `bash "$RUN_SKILL_DIR/scripts/review-gate.sh" record <plan> <type> changes-requested`.
  2. Do **not** clear or drop the `needs-review` tag and do **not** change
     `status`. Leave both as-is and report what the reviewer flagged.
  3. Commit the recorded verdict (plan 037): `changes-requested` is still a
     recorded `reviews:` entry, so the same invariant binds — it must not be
     left dirty (though this is not the "approve" framing; the plan remains
     blocked pending a fix). Commit only the plan file:
     ```bash
     git add "<plan-file>"
     git commit -m "chore(plan <id>): review changes-requested (<type>)" -m "Refs: docs/plans/<plan-file-basename>"
     ```

If no, print the list of plans still pending review and proceed to Step 6
(skipping the reviews does not skip the rest of the run — Step 5b's
re-validation and Step 6's summary still have to happen).

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

**Amendment gate (plan 091, Rule 2).** For every plan in this run, run:

```bash
bash "$RUN_SKILL_DIR/scripts/amendment-repass.sh" assert-rechecked <plan>
```

A plan whose `assert-rechecked` exits `EXIT_AMENDMENT_UNCHECKED` (39) is
reported `needs-fixes`, never `ready`, with the un-re-checked amendment named
(round, severity, trigger — the script prints exactly that). This is the mstack
analogue of the proposal's "CLEARED requires it for any P2+ amendment": a plan
whose own fix was never examined has not been cleared, it has been stamped.
Resolving it means running the scoped re-pass from Step 4b and recording the
result — never deleting the record, and never lowering the stored severity.

Two boundaries, both deliberate:

- Exit 0 with no records is **not** a clearance the gate issued. It means no
  amendment was ever captured for that plan. This is the rule's honest
  residual, and the reason the gate is described as an honest-path check: it
  fires when the doctor calls `capture`, and a plan edited outside plan-doctor
  leaves nothing to assert over.
- With `rules.amendment_repass` disabled, **do not consult `assert-rechecked`
  at all** — the script itself exits 0 when disabled, and a step that "checks"
  a disabled rule teaches the reader that the gate ran when it did not.

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
