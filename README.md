# mstack

**Human = architect. AI = builder.**

Plan it. Walk away. Read the changelog.

Autonomous plan execution for solo devs who work on main. You make every decision up front, the AI ships while you're gone, and you come back to a changelog of everything it did.

Built by [Matthew Aberham](https://github.com/aberhamm). For [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

---

## The solo-dev problem

Most AI coding tools assume a team workflow: feature branches, pull requests, human code review between AI runs. If you're a solo dev shipping on main, that machinery is overhead. You need something different.

You need a system where you make all the decisions up front (architecture, scope, acceptance criteria, how to verify it works) and then walk away. The AI executes directly on main with guard rails. It never pushes. When you come back, you read the changelog, spot-check anything that matters, and push.

The quality of autonomous execution comes down to two things: **how specific your plans are** and **how deep your test suite goes**.

---

## What "walk away" actually means

This is the concrete sequence:

**1. You plan.** Run `/mstack-plan-multi "add multi-tenant billing"`. It asks clarifying questions, researches your codebase, and writes ordered plan files with dependencies, acceptance criteria, and verification checks. You review and edit them.

**2. You validate.** Run `/mstack-plan-doctor`. It scores every plan on clarity, testability, scope-fit, and autonomy-readiness. It audits your test infrastructure (static analysis, unit tests, integration tests, E2E (Playwright/Cypress), API contracts) and reports your walk-away confidence level:

```
Walk-away confidence: HIGH
  Static analysis:  tsc --noEmit (strict mode)
  Unit tests:       vitest (127 tests)
  E2E tests:        playwright (14 specs)
  Missing:          API contract tests (non-blocking)
```

Plans below 8/10 on autonomy-readiness get auto-fixed from codebase analysis. Plans without executable verification get blocked.

**3. You leave.** Run `/goal all pending mstack plans are done or failed`. Close the laptop.

The AI picks plans in dependency order. For each plan, it:
- Implements the full scope
- Runs the health gate: typecheck + lint + unit tests + E2E + dead code analysis, each scored 0-10
- Executes plan-specific verification checks (`[cmd]`, `[assert]`, `[status]`)
- Runs code review (single reviewer, or 3 blind reviewers with cross-model routing for thorough mode)
- Commits with a conventional commit message referencing the plan
- Extracts learned patterns for future plans
- Moves to the next plan

If a plan fails, it enters structured investigation: 3 attempts per root cause category, max 3 categories (9 total strikes). If investigation exhausts all categories, the plan is marked failed with a detailed diagnosis and the next plan proceeds. No infinite loops.

**4. You come back.** Run `/mstack-changelog` and it syncs git history into a human-readable changelog:

```markdown
## [Unreleased]

### Added
- Multi-tenant billing schema with per-org isolation (plan 001)
- Stripe webhook integration for payment events (plan 002)
- Usage metering service with per-minute granularity (plan 003)
- Invoice generation with PDF export (plan 005)
```

Every commit references its plan file. You click through the changelog, spot-check anything that looks off with `git log -p`, and push when ready.

---

## Your test suite is your confidence level

mstack doesn't replace your tests; it runs them as a gate on every single plan. The health gate scores six categories with a weighted composite:

| Category | Weight | What it checks |
|---|---|---|
| Type check | 25% | tsc, mypy, or equivalent |
| Tests | 30% | Unit and integration test suites |
| Lint | 20% | ESLint, Ruff, or equivalent |
| Dead code | 15% | Unused exports, unreachable code |
| E2E | * | Playwright, Cypress, or `test:e2e` scripts |
| Shell lint | 10% | ShellCheck on bash scripts |

*E2E weight is redistributed if no framework is detected.*

Scores are tracked over time in `.mstack/health-history.jsonl`. If a plan degrades the composite score, even if all tests technically pass, it triggers investigation. "You added 200 lines of dead code" is a regression, not a pass.

**The investment is yours.** A project with Playwright E2E tests, comprehensive unit coverage, and strict TypeScript gets HIGH walk-away confidence. A project with three unit tests gets LOW. Plan-doctor tells you exactly which tier you're in and what's missing.

---

## The system gets smarter

Every plan execution extracts patterns, pitfalls, conventions, and dependencies into a self-healing knowledge base. A pitfall discovered in plan 5 ("the ORM doesn't support upsert on this table") surfaces as a constraint during plan 12 if it touches the same files.

Learnings have a lifecycle:
- **Confidence scores** (1-10) track how reliable each pattern is
- **Confidence decay** kicks in after 14 days without verification (-1 per cycle)
- **Auto-pruning** removes entries when >50% of their referenced files no longer exist
- **Deduplication** merges repeated discoveries instead of duplicating them

Health scores trend over time too. You can see whether your codebase is getting healthier or sicker across 10, 20, 50 plan executions, not just within a single run.

Your first plan execution is good. Your tenth is better. Your fiftieth is dramatically better.

---

## Context degradation and handoff

Long AI sessions accumulate noise: failed attempts, dead-end reasoning, stale assumptions. The more context the model carries, the worse its judgment gets. Context compaction doesn't help because the dead ends are real history.

`/mstack-handoff` captures only what matters: the goal, current state, files touched, what was tried and why it failed, what's been ruled out, and the single most promising next step. Paste it into a fresh session and it picks up cleanly.

The skill also triggers proactively: if the same fix has been attempted twice without success, it suggests a handoff rather than another retry.

---

## See it in action

The [`docs/example/`](docs/example/) directory contains a complete worked example: 5 plans for adding multi-tenant billing to a Next.js app, the health history showing scores improving from 7.8 to 9.4, the learned patterns that accumulated across plans, and the changelog the developer read when they came back.

---

## Install

**Requirements:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Git](https://git-scm.com/).

Open Claude Code and paste this. Claude does the rest.

> Install mstack: run **`git clone --single-branch --depth 1 https://github.com/aberhamm/mstack.git ~/.claude/skills/mstack && cd ~/.claude/skills/mstack && ./setup`** then add an "mstack" section to CLAUDE.md with routing rules so the user can say things like "create a plan for X" naturally. The routing rules: "create a plan for...", "plan out...", "break this down" → invoke /mstack-plan-multi. "validate plans", "check the backlog", "are plans ready" → invoke /mstack-plan-doctor. "run the plans", "execute the backlog" → invoke /mstack-run. "where are we", "what's next" → invoke /mstack-status. The three commands users need to know: 1) /mstack-plan-multi: decompose a goal into ordered plans, 2) /mstack-plan-doctor: validate plans are implementation-ready, 3) /goal all pending mstack plans are done or failed: execute the backlog autonomously.

**To update:**

```bash
cd ~/.claude/skills/mstack && git pull && ./setup
```

### With [skillshare](https://github.com/runkids/skillshare)

```bash
skillshare install aberhamm/mstack
```

### Your project needs a CLAUDE.md

mstack reads your project's `CLAUDE.md` to discover test, lint, and typecheck commands. At minimum:

```markdown
## Commands
- Test: `npm test`
- Lint: `npm run lint`
- Typecheck: `npx tsc --noEmit`
```

Run `/init` in Claude Code to auto-generate one.

---

## How it works

### Skills

**User-facing:**

| Skill | Purpose |
|---|---|
| `/mstack-ideate` | Divergent idea exploration before committing to plans |
| `/mstack-plan-multi` | Decompose a goal into ordered plans with dependencies |
| `/mstack-plan-new` | Scaffold a single plan file |
| `/mstack-plan-doctor` | Validate plans, score readiness, audit test infrastructure |
| `/mstack-backlog` | Reprioritize, defer, drop, or stash plans |
| `/mstack-status` | Read-only dashboard: where are we, what's next |
| `/mstack-handoff` | Capture session state for a clean restart |
| `/mstack-stash` | Park an unready idea for later |
| `/mstack-init` | Bootstrap a project for mstack (runs automatically on first use) |
| `/mstack-config` | Project settings: health commands, weights, review providers |
| `/mstack-changelog` | Sync CHANGELOG.md with git history |

**Internal (run automatically during execution):**

| Skill | When | Purpose |
|---|---|---|
| `mstack-run` | Every plan | Pick, implement, verify, review, commit one plan |
| `mstack-code-health` | Every plan | Score health 0-10, track trends, detect regressions |
| `mstack-code-review` | Every plan | 1 or 3 blind reviewers, cross-model routing |
| `mstack-investigate` | On failure | Category-aware debugging with strike rules |
| `mstack-learned-patterns` | Before and after | Apply relevant knowledge, extract new patterns |
| `mstack-checkpoint` | After each plan | Crash recovery state |

**Supporting references:**

| Reference | Purpose |
|---|---|
| `mstack-shared` | Shared cognitive frames for multi-perspective plan review and decomposition |

### Plan file format

Plans live in `docs/plans/` (preferred) or `plans/`:

```yaml
---
id: 3
title: Implement auth endpoints
status: pending
blocked-by: [1, 2]
needs-review: eng
created: 2026-05-18
---
```

Four required sections: **Requirements** (acceptance criteria as checkboxes), **Design** (files to change, approach, out of scope), **Tasks** (2-8 implementation steps), **Verification** (executable checks).

### Configuration

Optional. Most projects never need this. Settings live in `.mstack/config.json`:

| Setting | Default | Purpose |
|---|---|---|
| `health.commands.*` | auto-detect | Override test/lint/typecheck commands |
| `health.weights.*` | see scoring table | Adjust category weights |
| `review.provider` | `auto` | External model: auto, codex, gemini, claude-only |

---

## gstack integration

mstack is designed to work with [gstack](https://github.com/AiCodeCraft/gstack), an AI-powered development toolkit for Claude Code that adds browser automation, QA testing, cross-model code review, and interactive plan review skills.

**mstack works without gstack**, but the experience is significantly richer with it:

| Capability | Without gstack | With gstack |
|---|---|---|
| **Plan reviews** | Built-in auto-decision framework | Interactive CEO, eng, and design review skills |
| **Code review** | All-Claude blind scoring | Cross-model routing (Codex, Gemini) for generator/judge separation |
| **QA & browser testing** | Manual | `/browse`, `/qa` for automated browser-based verification |
| **Design review** | Not available | Visual design audit with `/design-review` |

```bash
npx gstack-cli@latest install
```

---

## How mstack is different

Most autonomous coding tools assume a team workflow: feature branches, pull requests, human code review between AI runs. mstack assumes you are one person committing to main.

Most tools treat test execution as a pass/fail gate. mstack scores each category 0-10, tracks trends over time, and flags regressions even when all tests pass, because "tests pass but dead code doubled" is a problem.

Most tools reset after each session. mstack accumulates project-specific knowledge (patterns, pitfalls, and conventions) with confidence decay and self-healing pruning. The system gets measurably better at your codebase over time.

---

## Design decisions

**Safety.** mstack commits locally but **never pushes, deploys, or merges** without human approval.

**Facts, not reasoning.** Checkpoints carry observable facts (errors, test output). Never agent reasoning. A fresh session forms its own conclusions from the evidence.

**Mandatory verification.** Every plan must have executable checks. If you can't describe how to verify it, the plan isn't ready.

---

## Recovering from failures

| Problem | Fix |
|---|---|
| A plan failed | Edit `status` back to `pending`, re-run |
| Worker crashed mid-plan | Checkpoint tracks progress. Reset to `pending` to retry |
| Dependency cycle | Plan-doctor detects and reports. Fix `blocked-by` fields |

---

## License

MIT
