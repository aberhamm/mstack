# mstack

Plan-driven autonomous workflow skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Write plans. Let the AI work the backlog.

## What is this?

mstack turns Claude Code into an autonomous backlog worker. You describe what you want to build — mstack decomposes it into ordered plan files, validates them, and executes them one at a time. Each plan produces a working increment committed directly to `main`. No feature branches, no PRs, no babysitting.

The system is built for a solo-dev workflow: you describe the goal, review `git log -p` when it's done, and push when you're ready.

```
/mstack-plan-backlog "Add user auth with email/password and OAuth"
  → Produces 5 ordered plan files in docs/plans/

/mstack-plan-doctor
  → Validates format, dependencies, coverage gaps, runs pending reviews

/loop /mstack-run
  → Autonomously implements each plan, verifies, reviews, commits, moves to the next
```

## Install

### With [skillshare](https://github.com/anthropics/skillshare)

```bash
skillshare install aberhamm/mstack
```

### Manual

Copy the skills into your Claude Code skills directory:

```bash
git clone https://github.com/aberhamm/mstack.git
cp -r mstack/skills/mstack-* ~/.claude/skills/
```

## Quick start

```bash
# 1. Configure your project (optional — auto-detects if skipped)
/mstack-config init

# 2. Decompose a goal into ordered plans
/mstack-plan-backlog "Add a REST API for managing user profiles with CRUD operations"

# 3. Validate the backlog
/mstack-plan-doctor

# 4. Execute autonomously
/loop /mstack-run
```

---

## Skills

mstack has 14 skills in two tiers: **user-facing commands** you type directly and **supporting skills** the worker invokes automatically. Supporting skills are also callable standalone for debugging, recovery, and manual workflows.

### User-facing commands (8)

| Skill | Purpose |
|---|---|
| `mstack-plan-backlog` | Decompose a goal into an ordered plan backlog |
| `mstack-plan-new` | Scaffold a single plan file |
| `mstack-plan-doctor` | Validate plans, run reviews, detect coverage gaps |
| `mstack-run` | Execute one plan (or loop through the whole backlog) |
| `mstack-status` | Read-only dashboard — where are we, what's next |
| `mstack-config` | Project settings — health commands, weights, providers |
| `mstack-handoff` | Session summary for stepping away |
| `mstack-changelog` | Sync CHANGELOG.md with git history |

### Supporting skills (6)

Called by `mstack-run` automatically. Also callable standalone.

| Skill | Called at | Purpose | When you'd call it manually |
|---|---|---|---|
| `mstack-code-health` | Step 5 (verify) | Run checks, score 0-10, track quality trends | Get a health dashboard without running a plan |
| `mstack-code-review` | Step 6 (review) | Cross-model blind review with confidence gating | Review uncommitted changes before committing |
| `mstack-investigate` | Step 5 (on failure) | Structured debugging with 3-strike rule | Debug any failing test or build |
| `mstack-checkpoint` | Step 7d (after commit) | Crash recovery state — facts, not reasoning | View the checkpoint dashboard |
| `mstack-simplify-code` | End of loop | Post-batch code consolidation | Simplify a specific file or commit range |
| `mstack-learned-patterns` | Steps 3c/7c | Pattern/pitfall knowledge base | Inspect, search, or prune learnings |

---

## How it works

### 1. Plan a backlog

```
/mstack-plan-backlog Add a REST API for managing user profiles with CRUD operations
```

The planner asks 2-4 clarifying questions, reads your codebase (`CLAUDE.md`, directory structure, existing plans, prior learnings), produces a DAG of plans with dependency ordering, and presents the breakdown for your approval. Plans are written to `docs/plans/` but not committed — you review and edit them first.

### 2. Validate with the doctor

```
/mstack-plan-doctor        # audit all plans
/mstack-plan-doctor 003    # audit a single plan
```

Multi-agent validation: per-plan checks (frontmatter, sections, deep code validation), cross-plan consistency (duplicate ids, dependency cycles, overlapping scope), coverage gap detection, and pending review execution.

When gstack review skills (`/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`) are installed, plan-doctor delegates to them for rich interactive reviews. When they're not installed, it falls back to a built-in auto-decision framework using 6 decision principles: choose completeness, boil lakes, pragmatic, DRY, explicit over clever, bias toward action.

### 3. Execute the backlog

```
/mstack-run            # one plan
/loop /mstack-run      # autonomous loop
```

Each iteration:

1. **Startup** — bail checks, load `.mstack/config.json`, recover from checkpoint
2. **Pick** — lowest-id pending plan with all dependencies met
3. **Claim** — set `status: in-progress`, commit (prevents parallel picks)
4. **Readiness gate** — blocks plans with placeholder content
5. **Learnings** — prune stale entries, surface relevant patterns
6. **Implement** — execute the plan fully, tracking every file touched
7. **Health check** — run mstack-code-health: score each tool 0-10, compute weighted composite, detect regressions. On FAIL/REGRESSED: run mstack-investigate (structured 3-strike debugging with mandatory reflection)
8. **Code review** — run mstack-code-review: 3 blind agents (correctness, conventions, simplicity), route one through external model if available, discard findings below confidence 7, fix critical/high
9. **Commit** — update plan status, commit by explicit file list, tag `mstack/plan-${ID}-done`
10. **Learn + checkpoint** — extract patterns, write crash recovery state
11. **Next** — schedule next iteration (if looping) or exit

On failure: surgical revert of only the files the skill touched, plan marked `status: failed`, loop continues to the next plan.

### 4. Check status anytime

```
/mstack-status          # full dashboard
/mstack-status 042      # single plan detail
```

Shows backlog state, health trend, review history, and session progress. Read-only.

---

## Plan file format

Plans live in `docs/plans/` (preferred) or `plans/` as numbered markdown files:

```
docs/plans/
  001-setup-database-schema.md
  002-add-user-model.md
  003-implement-auth-endpoints.md
```

### Frontmatter

```yaml
---
id: 3
title: Implement auth endpoints
status: pending              # pending | in-progress | done | failed | blocked
blocked-by: [1, 2]           # plan ids that must be done first
allows-migrations: false     # true only for plans that edit db/migrations/
needs-review: eng            # none | eng | design | ceo (comma-separated)
autonomy: full               # full | checkpoint | supervised
created: 2026-05-18
# Set on completion:
# completed: 2026-05-18
# reviewed: false
# qa: automated              # none | automated | e2e | browser
# Set on failure:
# failed-reason: "gate red: TypeScript errors in auth module"
# failed-at: 2026-05-18
---
```

### Autonomy levels

Each plan can override the project default (`/mstack-config set autonomy <level>`):

- **`full`** — no stops, fully autonomous (default)
- **`checkpoint`** — pauses after review for user approval before committing
- **`supervised`** — pauses after implementation for user inspection before verification

### Sections

Every plan has four sections:

**Requirements** — What problem this solves. Acceptance criteria as `- [ ]` checkboxes.

**Design** — How it works. Must include `**Files expected to change:**` and `**Out of scope:**`.

**Tasks** — 2-8 ordered implementation steps.

**Verification** — Additional checks beyond the default gate (optional).

### Status lifecycle

```
pending → in-progress → done
                      → failed
pending → blocked (incomplete spec or awaiting review)
```

A failed plan can be retried by editing its `status` back to `pending`.

---

## Configuration

### `/mstack-config`

```
/mstack-config init               # create .mstack/config.json with defaults
/mstack-config show               # display current settings with sources
/mstack-config set <key> <value>  # update a setting
/mstack-config reset              # restore defaults
```

Settings live in `.mstack/config.json` (gitignored, local to each checkout):

| Setting | Default | Purpose |
|---|---|---|
| `health.commands.*` | auto-detect | Override verification commands |
| `health.weights.*` | typecheck 25%, lint 20%, test 30%, deadcode 15%, shell 10% | Scoring weights (must sum to 100) |
| `review.provider` | `auto` | External model preference: auto, codex, gemini, claude-only |
| `autonomy` | `full` | Default autonomy level for new plans |
| `commit.conventional` | `true` | Use conventional commit format |
| `commit.trailer` | `true` | Add `Refs: docs/plans/...` trailer |
| `ignored_paths` | `[]` | Paths the worker should never edit |

When no config exists, mstack auto-detects everything from `CLAUDE.md` and built-in defaults. Config is optional.

### Notifications

To get notified when a loop completes, add your notification MCP tool to the `allowed-tools` list in `mstack-run/SKILL.md`:

```yaml
allowed-tools:
  # ...
  # - mcp__MCP_DOCKER__telegram-claude__send_message
```

---

## Project structure

```
your-repo/
  CLAUDE.md                    # project conventions (test commands, patterns, rules)
  docs/plans/                  # plan files
    001-setup-schema.md
    002-add-models.md
    ...
  .mstack/                     # gitignored, created automatically
    config.json                # project settings (mstack-config)
    learnings.jsonl            # project-level learnings
    health-history.jsonl       # health score trend data
    reviews/                   # review artifacts per plan
      plan-001.json
    checkpoints/               # crash recovery state
      latest.json
```

---

## Design decisions

### Two-tier skill naming

Skills are split into user-facing commands and supporting skills. The distinction answers: "Am I supposed to run this, or does the system run it?" User-facing commands are the 8 you type directly. Supporting skills are the 6 that `mstack-run` calls automatically. Supporting skills remain callable manually for debugging, recovery, and advanced workflows — they're transparent, not hidden.

### Why these names

- **`plan-backlog`** not "initiate" or "architect" — describes the output (an ordered backlog of plan files), not the action
- **`run`** not "work" or "execute" — natural language, reads well in loop mode (`/loop /mstack-run`)
- **`learned-patterns`** not "learnings" or "memory" — describes what's stored: patterns and pitfalls learned from execution
- **`code-health`** not "gate" or "verify" — it scores and tracks quality, not just binary pass/fail
- **`code-review`** not "review" — the prefix clarifies it's about code, not plan review
- Descriptive names over short names: `mstack-code-review` beats `mstack-review` because clarity matters more than brevity

### Discover and defer

Every skill works standalone. Each has a discovery step that checks what's available:

- **External models**: `command -v codex`, `command -v gemini` — for cross-model review
- **Ecosystem skills**: check skillshare for richer gstack skills (e.g., `/investigate`, `/health`, `/plan-eng-review`)
- **Graceful degradation**: always has built-in logic as fallback

mstack is portable — works alone, gets better when it discovers richer tools.

### Facts, not reasoning (checkpoint design)

Checkpoints carry observable facts: compiler errors, test output, attempt history, user context. They never carry agent reasoning, interpretations, or hypotheses. A fresh session gets evidence and forms its own conclusions. This prevents poisoned context windows where a wrong hypothesis from a crashed session biases the next one.

### Structured debugging over blind retries

The old approach: retry the verification gate twice and give up. The new approach: mstack-investigate runs structured 4-phase debugging (root cause investigation, pattern analysis, hypothesis testing, implementation) with a hard 3-strike rule and mandatory reflection ("What failed? Am I repeating myself?"). Three informed attempts beats ten blind retries.

### Blind scoring in code review

Three review agents work independently without seeing each other's output. This eliminates groupthink. Cross-model routing (one reviewer through Codex or Gemini when available) catches what self-review misses. Confidence gating at 7/10 filters noise.

### Safety model

mstack can edit, test, review, investigate, and commit locally, but it **never pushes, deploys, or merges** without human approval. Every commit is a forward commit on `main` — never amends, never rebases, never force-pushes.

---

## Recovering from failures

**A plan failed during execution:**
The plan's status is set to `failed` with a reason. All file changes are reverted. To retry: edit the plan's `status` back to `pending` and run `/mstack-run` again.

**The worker crashed mid-plan:**
The checkpoint system tracks progress. On the next run, `mstack-run` reads the checkpoint, identifies the crashed plan (still `in-progress`), skips it, and picks the next one. Reset the crashed plan to `pending` to retry it.

**A plan was blocked as incomplete:**
Fill in the Requirements, Design, and Tasks sections with real content, set `status: pending`, and re-run.

**The loop stopped unexpectedly:**
Run `/mstack-plan-doctor` — it detects orphan in-progress plans and offers to reset them to `pending`.

**A dependency cycle exists:**
`pick-next.sh` detects cycles and warns on stderr. Fix the `blocked-by` fields, then re-run the doctor.

---

## Upgrade from v1

If you used mstack v1 (8 skills), the renames are:

| v1 name | v2 name |
|---|---|
| `mstack-plan-initiate` | `mstack-plan-backlog` |
| `mstack-new-plan` | `mstack-plan-new` |
| `mstack-work-next-plan` | `mstack-run` |
| `mstack-learnings` | `mstack-learned-patterns` |

Plus 6 new skills: `mstack-code-health`, `mstack-code-review`, `mstack-investigate`, `mstack-checkpoint`, `mstack-status`, `mstack-config`.

To upgrade:

```bash
# Remove old skill directories
rm -rf ~/.config/skillshare/skills/mstack-{plan-initiate,new-plan,work-next-plan,learnings}

# Install v2
skillshare install aberhamm/mstack
```

Or manually:

```bash
rm -rf ~/.config/skillshare/skills/mstack-{plan-initiate,new-plan,work-next-plan,learnings}
rm -rf ~/.claude/skills/mstack-*
cp -r skills/mstack-* ~/.config/skillshare/skills/
skillshare sync
```

---

## License

MIT
