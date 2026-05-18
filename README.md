# mstack

Plan-driven autonomous workflow skills for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Write plans. Let the AI work the backlog.

## What is this?

mstack turns Claude Code into an autonomous backlog worker. You describe what you want to build — mstack decomposes it into ordered plan files, validates them, and executes them one at a time. Each plan produces a working increment committed directly to `main`. No feature branches, no PRs, no babysitting.

The system is built for a solo-dev workflow: you describe the goal, review `git log -p` when it's done, and push when you're ready.

```
/mstack-plan-initiate "Add user auth with email/password and OAuth"
  → Produces 5 ordered plan files in docs/plans/

/mstack-plan-doctor
  → Validates format, dependencies, coverage gaps, runs pending reviews

/loop /mstack-work-next-plan
  → Autonomously implements each plan, verifies, commits, moves to the next
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

## Skills

### Core workflow

| Skill | Purpose |
|---|---|
| `mstack-plan-initiate` | Decompose a goal into an ordered plan backlog |
| `mstack-plan-doctor` | Validate plans and run pending reviews |
| `mstack-work-next-plan` | Execute one plan (or loop through the whole backlog) |

### Utilities

| Skill | Purpose |
|---|---|
| `mstack-new-plan` | Scaffold a single plan file |
| `mstack-learnings` | Manage the self-healing knowledge base |
| `mstack-simplify-code` | Review and simplify changed code |
| `mstack-changelog` | Sync CHANGELOG.md with git history |
| `mstack-handoff` | Output a structured handoff for session continuity |

---

## How it works

### 1. Initiate a plan backlog

```
/mstack-plan-initiate Add a REST API for managing user profiles with CRUD operations
```

The initiator:
- Asks 2-4 clarifying questions (end-state, constraints, what's out of scope)
- Reads your codebase — `CLAUDE.md`, directory structure, existing plans, prior learnings
- Produces a DAG of plans with dependency ordering
- Presents the breakdown for your approval before writing any files
- Writes numbered plan files to `docs/plans/` (or `plans/`)

Each plan targets 1-3 hours of focused human work. Hard decisions (schema design, API contracts, architecture) go early in the sequence and get flagged for review. Mechanical follow-on work skips review.

Plans are written but **not committed** — you review and edit them first.

### 2. Validate with the doctor

```
/mstack-plan-doctor        # audit all plans
/mstack-plan-doctor 003    # audit a single plan
```

The doctor runs a multi-agent validation pass:

- **Per-plan validation** (parallelized): checks frontmatter fields, verifies sections have real content (not template placeholders), confirms referenced files exist, ensures acceptance criteria are testable
- **Cross-plan consistency**: detects duplicate ids, dangling dependency references, dependency cycles, overlapping file scope without dependencies, stale `in-progress` plans
- **Coverage gaps**: identifies missing pieces in the backlog and suggests running `/mstack-plan-initiate` to fill them
- **Pending reviews**: if any plans need CEO/eng/design review, offers to run them inline

The doctor produces a verdict: either "ready for autonomous execution" or a specific list of what needs fixing first.

### 3. Execute the backlog

Run a single plan:

```
/mstack-work-next-plan
```

Or loop through the entire backlog autonomously:

```
/loop /mstack-work-next-plan
```

Each iteration follows a strict sequence:

1. **Pick** — selects the lowest-id pending plan with all dependencies met
2. **Claim** — immediately sets `status: in-progress` and commits (prevents parallel sessions from picking the same plan)
3. **Readiness gate** — verifies the plan has real acceptance criteria, file paths, and tasks (not template placeholders). Blocks incomplete plans rather than guessing.
4. **Learnings** — prunes stale learnings, then surfaces relevant patterns from prior plan executions
5. **Implement** — executes the plan fully, tracking every file modified or created
6. **Verify** — runs your project's checks (typecheck, lint, tests). Up to 2 self-fix attempts if something fails.
7. **Review** — spawns 3 parallel review agents checking correctness, convention adherence, and simplicity. Applies fixes for critical/high issues.
8. **Commit** — updates plan status to `done`, commits by explicit file list (never `git add .`), includes a `Refs: docs/plans/NNN-...` trailer
9. **Learn** — extracts 0-2 learnings (patterns, pitfalls) for future plans
10. **Next** — schedules the next iteration (if looping) or exits

On failure: surgical revert of only the files the skill touched (preserves your parallel work), plan marked `status: failed` with a reason. The loop skips it and moves to the next plan.

### Parallel execution

You can run `/mstack-work-next-plan` in two terminal sessions simultaneously. The claim step (setting `status: in-progress` immediately after picking) prevents both sessions from grabbing the same plan.

---

## Plan file format

Plans live in `docs/plans/` (preferred) or `plans/` as numbered markdown files:

```
docs/plans/
  001-setup-database-schema.md
  002-add-user-model.md
  003-implement-auth-endpoints.md
  004-add-profile-crud-api.md
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

### Sections

Every plan has four sections:

**Requirements** — What problem this solves, from the user's perspective. Acceptance criteria as `- [ ]` checkboxes.

**Design** — How it works. Must include `**Files expected to change:**` (real file paths) and `**Out of scope:**`. Optionally: schemas, edge cases, approach notes.

**Tasks** — 2-8 ordered implementation steps. Concrete enough for autonomous execution.

**Verification** — Additional tests or checks beyond the default gate (optional).

### Status lifecycle

```
pending → in-progress → done
                      → failed
pending → blocked (incomplete spec or awaiting review)
```

A failed plan can be retried by editing its `status` back to `pending`.

---

## The other skills

### `/mstack-new-plan` — Scaffold a single plan

```
/mstack-new-plan Add rate limiting to the API -- depends-on 003,004
```

Creates a numbered plan file from the template with frontmatter pre-filled. Automatically assesses what type of review the plan needs based on the title (eng for architecture decisions, design for UI work, ceo for scope-defining changes, none for mechanical work). The body sections are left as template placeholders for you to fill in.

### `/mstack-learnings` — Knowledge base

```
/mstack-learnings list                      # show all learnings
/mstack-learnings search "error handling"   # find matching entries
/mstack-learnings prune                     # remove stale entries
```

Learnings are stored in `.mstack/learnings.jsonl` (project-level, gitignored) and `~/.mstack/learnings.jsonl` (global, cross-project). Each entry has a confidence score (1-10), file references, and a type (pattern, pitfall, convention, or dependency).

The knowledge base is self-healing:
- Entries referencing deleted files are pruned automatically
- Low-confidence entries decay and get removed after 30 days
- Conflicting entries are resolved (higher confidence wins)
- Reinforced entries get confidence bumps

The worker calls learnings automatically — you only need to invoke this skill directly if you want to inspect or manage the knowledge base.

### `/mstack-simplify-code` — Post-implementation review

```
/mstack-simplify-code                # review last commit
/mstack-simplify-code src/api/       # review specific file
/mstack-simplify-code HEAD~5..HEAD   # review commit range
/mstack-simplify-code branch         # review full branch diff
```

Checks changed code for:
- **Reuse** — duplicate logic that could use an existing utility
- **Clarity** — unnecessary nesting, vague names, missing intent comments
- **Consistency** — naming, imports, error handling vs project conventions
- **Efficiency** — N+1 patterns, unnecessary re-computation, missing early exits

Applies fixes and re-runs your verification gate. Never changes behavior — tests must pass identically before and after.

Called automatically at the end of a `/loop` run to consolidate reuse across all plans from that session.

### `/mstack-changelog` — Sync with git history

```
/mstack-changelog
```

Reads your existing `CHANGELOG.md`, finds the last recorded entry, diffs against `git log`, and drafts new entries in [Keep a Changelog](https://keepachangelog.com/) format. Entries are written in user-facing voice ("You can now export as CSV") not developer-facing ("Added CSV export endpoint"). Presents a draft for approval before writing. Includes hidden commit SHA comments for deduplication on re-runs.

### `/mstack-handoff` — Session continuity

```
/mstack-handoff
```

Outputs a structured summary covering: goal, current state, files touched, what's been tried and why it failed, what's been ruled out, and the single most promising next step. Designed to be pasted into a fresh Claude Code session after `/clear`.

The handoff is output in chat by default. Add a file request to write it as `YYYY-MM-DD-handoff-NN-summary.md` instead.

The skill will proactively suggest a handoff if you've been trying the same fix more than twice — a fresh session with a clean handoff is usually more productive than retrying with accumulated context noise.

---

## Project structure

```
your-repo/
  CLAUDE.md                    # project conventions (test commands, patterns, rules)
  docs/plans/                  # plan files (preferred location)
    001-setup-schema.md
    002-add-models.md
    ...
  .mstack/                     # gitignored, created automatically
    learnings.jsonl             # project-level learnings
```

mstack reads `CLAUDE.md` for your project's verification commands (defaults to `pnpm test`, `pnpm -r typecheck`, `pnpm -r lint` if not specified). It also reads conventions, naming patterns, and any explicit rules you've documented.

---

## Safety guarantees

- **Never pushes to remote.** You review `git log -p` and push when ready.
- **Never bypasses the verification gate.** If typecheck/lint/tests fail after retries, the plan is marked `failed` and all changes are surgically reverted.
- **Never uses `--no-verify`, `--no-gpg-sign`, or escape hatches.**
- **Never amends or rebases commits.** Each plan is one forward commit.
- **Never runs `git reset --hard` or `git add .`.** Commits use explicit file lists. Reverts only touch files the skill modified.
- **Never edits `db/migrations/`** unless the plan explicitly opts in with `allows-migrations: true`.
- **Never deletes a plan file.** Failed plans get `status: failed` with a reason.
- **Coexists with your in-progress work.** Tracks pre-existing dirty files and never touches them during implementation or rollback.

---

## Configuration

### Verification commands

mstack reads test/lint/typecheck commands from your `CLAUDE.md`. If none are specified, it defaults to:

```bash
pnpm -r typecheck && pnpm -r lint && pnpm test
```

### Notifications

To get notified when a loop completes, add your notification MCP tool to the `allowed-tools` list in `mstack-work-next-plan/SKILL.md`:

```yaml
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  # - mcp__MCP_DOCKER__telegram-claude__send_message
```

### Plans directory

By convention, plans go in `docs/plans/`. If that doesn't exist, mstack falls back to `plans/`. The directory is created automatically by `/mstack-plan-initiate` and `/mstack-new-plan`.

---

## Recovering from failures

**A plan failed during execution:**
The plan's status is set to `failed` with a reason. All file changes are reverted. To retry: edit the plan's `status` back to `pending` (optionally update the plan content based on the failure reason) and run `/mstack-work-next-plan` again.

**A plan was blocked as incomplete:**
The doctor or worker flagged it as having template placeholder content. Fill in the Requirements, Design, and Tasks sections with real content, set `status: pending`, and re-run.

**The loop stopped unexpectedly:**
Plans that were claimed (`in-progress`) but never completed can be reset. Run `/mstack-plan-doctor` — it detects orphan in-progress plans and offers to reset them to `pending`.

**A dependency cycle exists:**
`pick-next.sh` detects cycles and warns on stderr. Fix the `blocked-by` fields in the affected plans, then re-run the doctor.

## License

MIT
