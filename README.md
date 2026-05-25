# mstack

**Human = architect. AI = builder.**

Plan-driven autonomous workflow for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). You architect the plans. The AI executes them without supervision.

## Why this exists

Every AI coding tool I used still required babysitting. You'd describe a feature, watch the AI work, intervene when it went sideways, and repeat. The "AI writes code" part was fast. The "human watches AI write code" part was the bottleneck.

mstack eliminates the supervision. You define what to build — requirements, design decisions, verification criteria — in structured plan files. Then you walk away. The AI implements, verifies, debugs, reviews, and commits each plan autonomously. You review `git log` when you get back.

The insight: **AI doesn't need creativity, it needs architecture.** The more specific your plans, the better the output. mstack front-loads all human judgment into the planning phase and makes execution mechanical.

Built by [Matthew Aberham](https://github.com/aberhamm).

**Who this is for:** Solo developers and small teams who want to define what "done" looks like, then let the AI do the work.

## Quick start

1. Install mstack (30 seconds — see below)
2. Run `/mstack-plan-backlog "your feature idea"` — creates ordered plan files
3. Run `/mstack-plan-doctor` — validates plans are good enough to walk away from
4. Run `/goal all pending mstack plans are done or failed` — walk away
5. Come back, run `git log --oneline` — review what shipped

## Install — 30 seconds

**Requirements:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Git](https://git-scm.com/).

Open Claude Code and paste this. Claude does the rest.

> Install mstack: run **`git clone --single-branch --depth 1 https://github.com/aberhamm/mstack.git ~/.claude/skills/mstack && cd ~/.claude/skills/mstack && ./setup`** then add an "mstack" section to CLAUDE.md with routing rules so the user can say things like "create a plan for X" naturally. The routing rules: "create a plan for...", "plan out...", "break this down" → invoke /mstack-plan-backlog. "validate plans", "check the backlog", "are plans ready" → invoke /mstack-plan-doctor. "run the plans", "execute the backlog" → invoke /mstack-run. "where are we", "what's next" → invoke /mstack-status. The three commands users need to know: 1) /mstack-plan-backlog — decompose a goal into ordered plans, 2) /mstack-plan-doctor — validate plans are implementation-ready, 3) /goal all pending mstack plans are done or failed — execute the backlog autonomously.

**To update:**

```bash
cd ~/.claude/skills/mstack && git pull && ./setup
```

### With [skillshare](https://github.com/runkids/skillshare)

If you use skillshare to manage skills across multiple AI tools:

```bash
skillshare install aberhamm/mstack
```

---

## Philosophy

mstack splits development into two modes with a hard boundary:

| Phase | Command | You're involved? |
|---|---|---|
| **Plan** | `/mstack-plan-backlog "your goal"` | Yes — asks questions, you review the plans |
| **Validate** | `/mstack-plan-doctor` | Yes — you choose review posture, approve scope |
| **Execute** | `/goal all pending mstack plans are done or failed` | No — walk away, come back to `git log` |

**Planning is interactive.** You decompose goals, make every design decision, and specify how to verify each plan. Plan-doctor is your tool — you choose how aggressively to review scope.

**Execution is autonomous.** mstack-run picks up the validated backlog and works until it's empty. No stopping for approval. If a plan fails, it writes a diagnosis, marks it failed, and moves to the next one.

The contract between the two modes is the **plan file itself.** If the plan is good enough — clear requirements, explicit design, executable verification — execution is mechanical. The AI is an assistant that needs specific direction. Everything must be architected.

---

## What your project needs

### CLAUDE.md

mstack reads your project's `CLAUDE.md` to know how to run tests, lint, and type checks. Without it, the health gate won't know what commands to run. At minimum:

```markdown
# Project

## Commands
- Test: `npm test`
- Lint: `npm run lint`
- Typecheck: `npx tsc --noEmit`
```

Run `/init` in Claude Code to auto-generate one from your project.

### Project structure after first use

```
your-project/
  CLAUDE.md              ← your project conventions (you create this)
  docs/plans/            ← plan files (mstack creates this)
    001-setup-schema.md
    002-add-models.md
  .mstack/               ← mstack state, gitignored (auto-created)
    config.json
    learnings.jsonl
    health-history.jsonl
    reviews/
    checkpoints/
```

---

## Skills

### Core pipeline (7 user-facing)

| Skill | Purpose |
|---|---|
| `/mstack-plan-backlog` | Decompose a goal into an ordered plan backlog |
| `/mstack-plan-new` | Scaffold a single plan file |
| `/mstack-plan-doctor` | Validate plans are execution-ready (the last gate before walking away) |
| `/mstack-backlog` | View and interactively reprioritize/groom the backlog |
| `/mstack-run` | Execute one plan autonomously |
| `/mstack-status` | Read-only dashboard — where are we, what's next |
| `/mstack-stash` | Save an unresolved conversation thread for later |

### Supporting skills (auto-invoked by mstack-run)

| Skill | Called at | Purpose |
|---|---|---|
| `mstack-code-health` | Step 5 | Score each check tool 0-10, detect regressions |
| `mstack-code-review` | Step 6 | 1 reviewer (default) or 3 blind reviewers (`review: thorough`) |
| `mstack-investigate` | Step 5 (on failure) | Category-aware debugging (3 strikes/category, max 3 categories) |
| `mstack-learned-patterns` | Steps 3c/7c | Pattern/pitfall knowledge base — feeds back into plan-doctor |
| `mstack-checkpoint` | Step 7d | Crash recovery state (internal) |

### Utility skills

| Skill | Purpose |
|---|---|
| `/mstack-config` | Project settings — health commands, weights, review providers |
| `/mstack-handoff` | Session summary for context switching |
| `/mstack-changelog` | Sync CHANGELOG.md with git history |

---

## How it works

### Plan-doctor: the architect's review tool

Plan-doctor answers one question: **"Can I walk away and trust the worker to finish this backlog?"**

You choose the review posture — how aggressively to challenge scope:

| Posture | When to use |
|---|---|
| **Expand** | Early exploration. "What's left on the table?" |
| **Selective** | Solid backlog. Cherry-pick 1-3 high-leverage additions. |
| **Hold** | Ready to run. Maximum rigor on what's here. |
| **Reduce** | Ship fast. Strip to essentials. |

Regardless of posture, the doctor always:
- **Audits testing infrastructure** — what tiers of testing exist (static analysis, unit, integration, E2E, API contracts) and what's missing. Prints a walk-away confidence level (HIGH/MEDIUM/LOW) with specific recommendations
- Scores each plan on 4 dimensions: clarity, testability, scope-fit, autonomy-readiness
- **Auto-fixes** plans below 8/10 on autonomy-readiness from codebase analysis
- **Auto-generates** executable verification checks from acceptance criteria
- **Blocks** plans without executable verification (unless `verification: health-only`)
- **Surfaces learnings** from previous executions — pitfalls the worker hit before

### Execution loop

`/goal` owns the loop. Each iteration, `mstack-run` does one plan:

1. **Pick** — lowest-priority pending plan with dependencies met
2. **Claim** — set `status: in-progress`, commit
3. **Gate** — verify the plan is fully specified
4. **Learnings** — apply relevant patterns from previous executions
5. **Implement** — execute the plan fully
6. **Health check** — typecheck/lint/test scored 0-10
7. **Verification** — execute the plan's `[cmd]`, `[assert]`, `[status]` checks
8. **Code review** — 1 reviewer (default) or 3 blind (`review: thorough`)
9. **Commit** — conventional commit with plan reference
10. **Learn + checkpoint** — extract patterns, write crash recovery state

On failure: surgical revert, plan marked `status: failed`, next plan continues.

### Investigation

When checks fail, mstack-investigate runs structured debugging:
- 3 strikes per distinct root cause category, max 3 categories (9 total)
- Mandatory reflection before each attempt
- After all categories exhausted: plan fails with detailed diagnosis

---

## Plan file format

Plans live in `docs/plans/` (preferred) or `plans/`:

```yaml
---
id: 3
title: Implement auth endpoints
status: pending
blocked-by: [1, 2]
allows-migrations: false
needs-review: eng
# verification: health-only  # only if no executable checks are possible
# review: thorough           # for 3-blind-reviewer pipeline
created: 2026-05-18
---
```

Every plan has four sections:

**Requirements** — What problem this solves. Acceptance criteria as `- [ ]` checkboxes.

**Design** — How it works. `**Files expected to change:**` and `**Out of scope:**` required. Every decision must be made here — the AI should never need to guess.

**Tasks** — 2-8 ordered implementation steps.

**Verification** — **Mandatory.** At least one executable check (`[cmd]`, `[assert]`, or `[status]`). If you can't describe how to verify it, the plan isn't ready.

---

## Configuration

Optional. Settings live in `.mstack/config.json` (gitignored):

| Setting | Default | Purpose |
|---|---|---|
| `health.commands.*` | auto-detect | Override test/lint/typecheck commands |
| `health.weights.*` | typecheck 20%, lint 15%, test 25%, e2e 20%, deadcode 10%, shell 10% | Scoring weights |
| `review.provider` | `auto` | External model: auto, codex, gemini, claude-only |
| `commit.conventional` | `true` | Conventional commit format |

Most projects never need to touch config. mstack auto-detects from `CLAUDE.md`.

---

## Design decisions

**Human = architect, AI = builder.** The human's job ends when the plans are signed off. Everything after that runs to completion without a prompt. Quality is front-loaded into plan authoring, not sprinkled through execution.

**mstack is as good as your test suite.** The health gate runs everything it finds — typecheck, lint, unit tests, Playwright, Cypress, integration suites. The more testing infrastructure you invest in, the more walk-away confidence you get. Plan-doctor audits your setup and tells you exactly what's covered and what's not.

**Mandatory verification.** Every plan must have executable checks. Typecheck/lint/test verify code correctness, not feature correctness. If you can't describe how to test it, the plan isn't ready.

**Learnings feed the architect.** When the system learns "this ORM doesn't support upsert" from a failed plan, that surfaces during plan-doctor validation — not just during execution.

**Facts, not reasoning.** Checkpoints carry observable facts (errors, test output). Never agent reasoning. A fresh session forms its own conclusions.

**Safety.** mstack commits locally but **never pushes, deploys, or merges** without human approval.

---

## Recovering from failures

| Problem | Fix |
|---|---|
| A plan failed | Edit `status` back to `pending`, re-run |
| Worker crashed mid-plan | Checkpoint tracks progress. Next run skips crashed plan. Reset to `pending` to retry |
| Dependency cycle | Plan-doctor detects and reports. Fix `blocked-by` fields |

---

## License

MIT
