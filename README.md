# mstack

**Human = architect. AI = builder.**

Plan-driven autonomous workflow skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). You architect the plans. The AI executes them without supervision.

## Philosophy

mstack splits software development into two modes with a hard boundary between them:

1. **Planning mode (interactive, rigorous, human-driven).** You decompose goals into plans, make every design decision, and specify how to verify each plan programmatically. Plan-doctor is your tool — you choose how aggressively to review (expand scope? lock it down? strip to essentials?), and it interrogates your plans accordingly. This is where all human judgment lives.

2. **Execution mode (zero interaction, fully autonomous).** mstack-run picks up the validated backlog and works until it's empty. No stopping for approval. No "what do you think?" prompts. If a plan fails, it writes a diagnosis, marks it failed, and moves to the next one. You review `git log -p` when you get back.

The contract between the two modes is the **plan file itself.** If the plan is good enough — clear requirements, explicit design, executable verification — execution is mechanical. If execution fails, that's a plan quality problem, not an execution problem.

The AI is an assistant that needs very specific direction. Everything must be architected.

## Quick start

```bash
# 1. Decompose a goal into ordered plans
/mstack-plan-backlog "Add user auth with email/password and OAuth"

# 2. Validate plans are good enough to walk away from
/mstack-plan-doctor

# 3. Walk away — execute autonomously
/goal all pending mstack plans are done or failed
```

## Install

### With [skillshare](https://github.com/anthropics/skillshare)

```bash
skillshare install aberhamm/mstack
```

### Manual

```bash
git clone https://github.com/aberhamm/mstack.git ~/.config/skillshare/skills/mstack
cd ~/.config/skillshare/skills/mstack && ./setup
skillshare sync
```

---

## Skills

### Core pipeline (7 user-facing)

| Skill | Purpose |
|---|---|
| `mstack-plan-backlog` | Decompose a goal into an ordered plan backlog |
| `mstack-plan-new` | Scaffold a single plan file |
| `mstack-plan-doctor` | Validate plans are execution-ready (the last gate before walking away) |
| `mstack-backlog` | View and interactively reprioritize/groom the backlog |
| `mstack-run` | Execute one plan (or loop through the whole backlog) |
| `mstack-status` | Read-only dashboard — where are we, what's next |
| `mstack-stash` | Save an unresolved conversation thread for later |

### Supporting skills (auto-invoked by mstack-run)

| Skill | Called at | Purpose |
|---|---|---|
| `mstack-code-health` | Step 5 | Score each check tool 0-10, detect regressions |
| `mstack-code-review` | Step 6 | Configurable review: 1 reviewer (default) or 3 blind reviewers (`review: thorough`) |
| `mstack-investigate` | Step 5 (on failure) | Category-aware debugging (3 strikes/category, max 3 categories) |
| `mstack-learned-patterns` | Steps 3c/7c | Pattern/pitfall knowledge base — feeds back into plan-doctor |
| `mstack-checkpoint` | Step 7d | Crash recovery state (internal, not user-facing) |

### Utility skills (not part of core pipeline)

| Skill | Purpose |
|---|---|
| `mstack-config` | Project settings — health commands, weights, review providers |
| `mstack-handoff` | Session summary for context switching |
| `mstack-changelog` | Sync CHANGELOG.md with git history (ship-time utility) |

---

## How it works

### The three commands

```
/mstack-plan-backlog  →  Create plans (interactive, human-driven)
/mstack-plan-doctor   →  Validate plans (last gate before walking away)
/goal ...             →  Execute plans (fully autonomous, zero interaction)
```

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
- Scores each plan on 4 dimensions: clarity, testability, scope-fit, autonomy-readiness
- **Auto-fixes** plans below 8/10 on autonomy-readiness (fills missing decisions from codebase analysis)
- **Auto-generates** executable verification checks from acceptance criteria
- **Blocks** plans without executable verification (unless `verification: health-only` is set)
- **Surfaces learnings** from previous plan executions — pitfalls the worker hit before

### Execution loop (mstack-run)

Each iteration, fully autonomous:

1. **Pick** — lowest-priority pending plan with dependencies met
2. **Claim** — set `status: in-progress`, commit
3. **Gate** — verify the plan is fully specified (blocks incomplete specs)
4. **Learnings** — apply relevant patterns from previous executions
5. **Implement** — execute the plan fully
6. **Health check** — typecheck/lint/test scored 0-10
7. **Verification** — execute the plan's `[cmd]`, `[assert]`, `[status]` checks
8. **Code review** — 1 reviewer (default) or 3 blind reviewers (`review: thorough`)
9. **Commit** — conventional commit with plan reference
10. **Learn + checkpoint** — extract patterns, write crash recovery state

On failure: surgical revert, plan marked `status: failed`, next plan continues. Failures never block the backlog.

### Investigation: category-aware strikes

When health checks or verification fail, mstack-investigate runs structured debugging:
- 3 strikes per distinct root cause category
- Max 3 categories (up to 9 total attempts)
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

### Sections

Every plan has four sections:

**Requirements** — What problem this solves. Acceptance criteria as `- [ ]` checkboxes.

**Design** — How it works. Must include `**Files expected to change:**` and `**Out of scope:**`. Every decision must be made here — the AI should never need to guess.

**Tasks** — 2-8 ordered implementation steps.

**Verification** — **Mandatory.** At least one executable check (`[cmd]`, `[assert]`, or `[status]`). If you can't describe how to verify it programmatically, the plan isn't ready.

---

## Configuration

Settings live in `.mstack/config.json` (gitignored, local to each checkout):

| Setting | Default | Purpose |
|---|---|---|
| `health.commands.*` | auto-detect | Override verification commands |
| `health.weights.*` | typecheck 25%, lint 20%, test 30%, deadcode 15%, shell 10% | Scoring weights |
| `review.provider` | `auto` | External model: auto, codex, gemini, claude-only |
| `commit.conventional` | `true` | Conventional commit format |

When no config exists, mstack auto-detects everything from `CLAUDE.md` and built-in defaults.

---

## Design decisions

### Human = architect, AI = builder

The human's job ends when the plans are signed off. Everything after that — implementation, verification, debugging, review, commit — runs to completion without a single prompt. The quality gate is front-loaded into plan authoring and validation, not sprinkled through execution.

### Mandatory verification

Every plan must have executable verification checks. "Trust the health gate" is not enough — typecheck/lint/test verify code correctness, not feature correctness. If you can't describe how to test it, the plan isn't ready. The only escape hatch is `verification: health-only` in frontmatter, which the architect must explicitly set.

### Learnings feed the architect, not just the builder

When the system learns "this ORM doesn't support upsert" from a failed plan, that surfaces during plan-doctor validation so the architect can adjust the design. Failures improve future plans, not just future implementations.

### Facts, not reasoning (checkpoint design)

Checkpoints carry observable facts: compiler errors, test output, attempt history. They never carry agent reasoning or hypotheses. A fresh session gets evidence and forms its own conclusions.

### Safety model

mstack can edit, test, review, investigate, and commit locally, but it **never pushes, deploys, or merges** without human approval.

---

## Recovering from failures

**A plan failed:** Status is set to `failed` with a reason. Changes are reverted. Edit `status` back to `pending` and re-run.

**The worker crashed mid-plan:** Checkpoint tracks progress. Next run reads checkpoint, skips the crashed plan, picks the next one. Reset the crashed plan to `pending` to retry.

**A dependency cycle exists:** Plan-doctor detects cycles and reports them. Fix the `blocked-by` fields.

---

## License

MIT
