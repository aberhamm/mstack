# mstack

**Human = architect. AI = builder.**

Plan it. Walk away. Read the changelog.

Autonomous plan execution for solo devs who work on main. You make every decision up front, the AI ships while you're gone, and you come back to a changelog of everything it did.

Built by [Matthew Aberham](https://github.com/aberhamm). For Codex and Claude Code.

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

**3. You execute.** Invoke `mstack-run` to execute one ready plan. In a harness
with a verified goal driver, use `/goal all pending mstack plans are done or failed via mstack-run orchestration`
to continue across the backlog. MStack does not install that driver; see the
[per-harness instructions](#install) before starting unattended work.

The AI picks plans in dependency order. For each plan, it:
- Keeps the goal's main thread as orchestrator and delegates source work to a dedicated worker subagent
- Implements the full scope
- Runs the health gate: typecheck + lint + unit tests + E2E + dead code analysis, each scored 0-10
- Executes plan-specific verification checks (`[cmd]`, `[assert]`, `[status]`)
- Simplifies the plan diff without changing behavior, then reviews the result (single reviewer, or 3 blind reviewers with cross-model routing for thorough mode)
- Writes the review outcome into the plan's `reviews:` frontmatter, which is the record the completion gate reads
- Checks the plan is actually completable (`assert-completable`: every required review has a passing record) before it is allowed to write `status: done`
- Commits with a conventional commit message referencing the plan, and tags it `mstack/plan-NNN-done`
- Extracts learned patterns for future plans
- Moves to the next plan

A plan whose required reviews are missing cannot be marked done, by the agent or by hand: a git hook rejects the commit. See [Enforcement](#enforcement-mstack-installs-git-hooks-in-your-repo).

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
| Type check | 20 | tsc, mypy, or equivalent |
| Tests | 25 | Unit and integration test suites |
| E2E | 20 | Playwright, Cypress, or `test:e2e` scripts |
| Lint | 15 | ESLint, Ruff, or equivalent |
| Dead code | 10 | Unused exports, unreachable code |
| Shell lint | 10 | ShellCheck on bash scripts |

Weights are relative, not a percentage of a fixed total. A category with no
detected tool is skipped and its weight is redistributed over the categories
that ran, so a repo with no Playwright is still scored out of 10 on the tools
it actually has.

These are defaults, and they live in exactly one place: `DEFAULT_CONFIG` in
`skills/mstack-run/scripts/config.sh`. Override any of them per project with
`/mstack-config` (`health.weights.*` in `.mstack/config.json`). If a weight
cannot be read, the gate fails closed with `FAILURES:config-unreadable` rather
than quietly scoring against a different set of numbers.

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

`/mstack-handoff` captures only what matters: the goal, current state, files touched, what was tried and why it failed, what's been ruled out, and the single most promising next step. You can output it in chat or save a **handoff checkpoint** to `.mstack/handoffs/` — then resume in a new session with `resume from handoff <name>`, no copy-paste needed. Checkpoints auto-delete on resume and auto-prune after 7 days.

Handoff discovery is deterministic. `/mstack-handoff list` shows checkpoints
for the current repo with each file path, age, short summary, and exact
`resume from handoff <summary>` command. `/mstack-handoff list --all-projects`
also scans the current repo plus `$HOME/_projects` and `$HOME/dev/projects`,
following symlinked roots and deduplicating canonical paths while avoiding
`.git`, `node_modules`, `.pnpm`, and build-output directories. Empty
`.mstack/handoffs/` directories are reported separately from projects that have
no handoff directory.

Resume lookup is single-use and predictable: `resume from handoff` loads the
newest current-repo checkpoint, while `resume from handoff <summary>` must
match exactly one checkpoint summary. Ambiguous summaries are reported instead
of guessed.

The skill also triggers proactively: if the same fix has been attempted twice without success, it suggests a handoff rather than another retry.

---

## See it in action

The [`docs/example/`](docs/example/) directory contains a complete worked example: 5 plans for adding multi-tenant billing to a Next.js app, the health history showing scores improving from 7.8 to 9.4, the learned patterns that accumulated across plans, and the changelog the developer read when they came back.

---

## Install

MStack's primary targets are **Codex and Claude Code**. Other hosts can discover
the skills without necessarily supporting the complete execution workflow.

### Support and evidence

Official feature documentation checked **2026-10-08**. "Experimental" describes
MStack integration, not the vendor's skill feature.

| Harness | MStack status | Invocation | Execution prerequisite |
|---|---|---|---|
| Codex CLI / supported Codex sessions | Primary target; deterministic shell smoke tested | `$mstack-run`, `/skills`, or natural language | Worker and independent reviewer subagents available |
| Claude Code | Primary target; live execution not revalidated in this compatibility change | `/mstack-run` or natural language | `Agent` tool and sufficient nesting depth |
| Copilot in VS Code **Local** | Experimental; install/resources tested, no live IDE run | `/mstack-run` or natural language | Agent mode, `agent/runSubagent`, nested delegation enabled |
| Copilot in Visual Studio | Experimental discovery/planning/status; autonomous execution **unverified** | Ask explicitly to use a named skill in agent mode | No verified MStack worker-to-reviewer delegation mechanism |
| Cursor / Gemini CLI | Experimental discovery; execution unvalidated | Cursor: slash skill; Gemini: ask to use the skill | Harness-specific delegation still needs validation |
| Copilot CLI / cloud / remote hosts | No validated MStack execution support | Consult the host's documentation | Do not assume VS Code Local capabilities apply |

The automated fixtures test shell behavior, not model behavior. Windows copy
selection is simulated on macOS; this is **not** evidence of a Windows or Visual
Studio end-to-end run. Before promoting a host, record its OS/client version and
verify discovery, resource reads, worker → reviewer delegation, health/review
gates, local commit, archive/tag, and a clean worktree.

### Prerequisites

- Git, Bash, standard Unix tools, and **jq** for the full workflow, including
  scoped execution manifests. Configure Git identity and any required signing.
- The project's actual build/test/lint tools and an accurate Health Stack.
- An authenticated coding agent with permission to read/edit the project and
  run the required terminal commands. Approval prompts can interrupt unattended
  work; installing a skill does not grant permissions.
- On Windows, use **Git Bash** or a consistent **WSL** environment. Native
  PowerShell/cmd are not MStack script runtimes. Setup uses managed copies under
  Git Bash to avoid symlink privileges. In Windows Visual Studio, use the
  Windows user's profile; a WSL `~` directory is a different location. In VS Code
  Remote/WSL, install on the host where the agent and terminal actually run.
- GStack is optional. The examples use `--without-gstack` for a standalone
  installation; omit it to install the optional local GStack MStack profile.

### Clone once, choose a skills destination

Run these commands in Bash. Keep the checkout outside the discovery directory
to avoid duplicate skills on hosts that recursively scan directories.

```bash
git clone --single-branch --depth 1 https://github.com/aberhamm/mstack.git "$HOME/mstack"
cd "$HOME/mstack"
```

Then choose **one** destination from your harness section below. Setup installs
the entire set, including the shared resources. Do not copy only SKILL.md files.

### Codex

[Official skills documentation](https://learn.chatgpt.com/docs/build-skills)
documents personal `~/.agents/skills` and repository `.agents/skills` discovery.

```bash
mkdir -p "$HOME/.agents/skills"
MSTACK_SKILL_DIR="$HOME/.agents/skills" ./setup --without-gstack
bash bin/mstack-install-agents --host codex --project /absolute/path/to/your-repo
```

In a new session, use `/skills` to verify discovery, then invoke
`$mstack-status`. Use `$mstack-run` for one plan. The worker adapter is optional
when the host exposes a generic worker tool; delegation itself is mandatory.
The installer writes adapters into the **consumer repo**, not just MStack's checkout.

### Claude Code

[Official skills documentation](https://code.claude.com/docs/en/skills)
documents personal `~/.claude/skills` and repository `.claude/skills`.

```bash
mkdir -p "$HOME/.claude/skills"
MSTACK_SKILL_DIR="$HOME/.claude/skills" ./setup --without-gstack
```

Start a new session and check `/mstack-status` in the slash menu. Use
`/mstack-run` for one plan. Read shared guidance through a thin `CLAUDE.md`:

```markdown
@AGENTS.md
```

The worker must be able to invoke independent reviewers. Check the actual
client and its configured nesting limit; see
[Claude subagents](https://code.claude.com/docs/en/sub-agents).

### GitHub Copilot in VS Code — experimental

Use a current stable VS Code with GitHub Copilot access and a **Local** session
in **Agent** mode. Skills are GA from 1.109; slash invocation arrived in 1.109.3.
Those minimums do not establish support for every current delegation option.
See [release notes](https://code.visualstudio.com/updates/v1_109).

```bash
mkdir -p "$HOME/.copilot/skills"
MSTACK_SKILL_DIR="$HOME/.copilot/skills" ./setup --without-gstack
bash bin/mstack-install-agents --host copilot-vscode --project /absolute/path/to/your-repo
```

VS Code discovers repository `.github/skills`, `.claude/skills`,
`.agents/skills`, and personal `~/.copilot/skills`, `~/.claude/skills`,
`~/.agents/skills`. Verify the loaded path through Chat customizations or
diagnostics, then run `/mstack-status`.
[Skills documentation](https://code.visualstudio.com/docs/agent-customization/agent-skills)

Enable **Run Subagent** (`agent/runSubagent`) and set:

```json
{
  "chat.subagents.allowInvocationsFromSubagents": true
}
```

MStack's worker needs this to call reviewers. Before execution, the skill
requires a read-only worker → reviewer probe. Calls are stateless; the parent
must provide complete briefs and resolved paths. Missing delegation stops the
run before plan mutation. The adapters are subagent-only and need not appear
in the user-facing agent picker.
[Subagent documentation](https://code.visualstudio.com/docs/agents/run/subagents)

### GitHub Copilot in Visual Studio — experimental, supervised only

Requires **Visual Studio 2026 18.5+**, GitHub Copilot access, and **agent mode**.
The skill-authoring panel has separate Insiders/version requirements; manual
file installation does not require that panel.
[Official Visual Studio skills documentation](https://learn.microsoft.com/en-us/visualstudio/ide/copilot-agent-skills?view=visualstudio)

From **Git Bash in the Windows user profile**:

```bash
mkdir -p "$HOME/.copilot/skills"
MSTACK_SKILL_DIR="$HOME/.copilot/skills" ./setup --without-gstack
bash bin/mstack-install-agents --host copilot-visual-studio --project /c/path/to/your-repo
```

Official discovery locations match the VS Code skill locations above. Ask
Copilot: **"Use the mstack-status skill to show the backlog."** Verify the skill
activation and source path. Do not assume VS Code's slash commands work here.

The optional worker/reviewer files are **supervised role templates**. Select
them in the agent picker or mention them with `@`; neither action proves
isolated delegation. Visual Studio tool identifiers differ from VS Code's, so
use the Visual Studio adapter profile. User-level agents also differ:
Visual Studio defaults to `%USERPROFILE%\.github\agents`; this installer uses
repository `.github/agents` to avoid that ambiguity.
[Custom agents documentation](https://learn.microsoft.com/en-us/visualstudio/ide/copilot-specialized-agents?view=visualstudio)

**Do not use `mstack-run` here yet.** There is no verified MStack nested
delegation path. Planning/status may work experimentally, but any phase that
requires an unavailable subagent must stop rather than substitute self-review.

### Other hosts and Skillshare

Cursor and Gemini CLI document `.agents/skills` discovery; their native
directories are `.cursor/skills` and `.gemini/skills` (also under `~`).
Use the same explicit-destination setup pattern, then verify discovery in the
host. This does not validate execution.
[Cursor skills](https://cursor.com/help/customization/skills) ·
[Gemini skills](https://geminicli.com/docs/cli/using-agent-skills/)

```bash
skillshare install aberhamm/mstack
```

Skillshare distributes to its configured targets. Inspect the actual installed
paths and host discovery; synchronization is not a support guarantee.

### Repository-local skills and adapters

For team-shared skills, use the host's documented repository destination:

```bash
mkdir -p /absolute/path/to/your-repo/.github/skills
MSTACK_SKILL_DIR=/absolute/path/to/your-repo/.github/skills \
  MSTACK_LINK_MODE=copy ./setup --without-gstack
```

Use `.agents/skills` for Codex or `.claude/skills` for Claude. Commit copies,
not symlinks into your private checkout. The resolver loads sibling resources;
copies work even without the original checkout. Missing source metadata
disables update notices with a visible message, not execution.

Adapter installation is explicit and refuses to overwrite different existing
files. Re-running against identical files is safe; merge future adapter changes
manually. Switching between the two Copilot adapter profiles requires the same
manual comparison because their filenames are shared.

### Project guidance and first run

Keep shared routing and health commands in `AGENTS.md`. For Copilot, add a
short `.github/copilot-instructions.md` that tells the agent to read
`AGENTS.md` before using MStack; do not use Claude's `@AGENTS.md` syntax there.

```markdown
Use mstack-plan-multi for decomposing goals into plans.
Use mstack-plan-doctor to validate plans and run required reviews.
Use mstack-status for backlog status.
Use mstack-run for one ready plan, only when harness delegation is verified.

## Health Stack
- test: npm test
- lint: npm run lint
- typecheck: npx tsc --noEmit
```

Replace the sample commands with your project's real checks. Invoke
`mstack-init --with-agent-docs` using your harness's skill invocation syntax
to bootstrap MStack. It installs enforcement Git hooks in the consumer repo.

The portable workflow is **plan → validate → execute one plan**. A continuing
`/goal` driver is a separate harness capability, not a command installed by
MStack. Only use it where available and verified; otherwise invoke the next
iteration explicitly. Skill examples elsewhere use Claude-style slash syntax;
use the invocation from your harness row.

### Updates and installation paths

```bash
cd "$HOME/mstack"
git pull --ff-only
MSTACK_SKILL_DIR="$HOME/.copilot/skills" ./setup --without-gstack
```

Use the **same destination and copy/symlink mode** as the original installation.
Managed copies refresh on setup. Setup refuses to replace unmarked directories.

Without an explicit destination, setup recognizes personal Skillshare, Agents,
Codex, Claude, Copilot, Cursor, and Gemini skill parents. A development checkout
uses an existing Skillshare source, or creates no links. It never installs into
an arbitrary parent directory.

Skills bootstrap the shared resolver from their loaded file path. Explicit
`MSTACK_SKILL_DIR` wins, then sibling skills, then personal compatibility
locations. Hooks use the installation recorded by init in local Git config
(`mstack.skillDir`), with repository/personal fallbacks. Re-run init after
moving an installation.

Update notices use the source checkout, never the consumer repo. They share
`~/.mstack/last-update-check`, fetching at most hourly when current or every
12 hours when behind. Set `MSTACK_UPDATE_CHECK=false` to disable, or tune
`MSTACK_UPDATE_CHECK_TTL` / `MSTACK_UPDATE_AVAILABLE_TTL` in seconds.

### Compatibility checks

From the MStack checkout:

```bash
bash bin/mstack-setup-smoke
bash skills/mstack-run/scripts/install-paths-smoke.sh
ruby bin/mstack-metadata-check
ruby bin/mstack-metadata-smoke
bash bin/mstack-codex-smoke
```

Ruby is needed only for the development metadata check. It parses YAML and
enforces the **1,024-character description limit**, valid names, and string
`allowed-tools` metadata. Tool names remain harness-specific.

The Codex smoke defaults to deterministic shell checks in a disposable repo.
`bash bin/mstack-codex-smoke --codex` additionally runs a real Codex execution;
it requires a configured Codex CLI and available model. It is not evidence of
Copilot compatibility. For the actual delegation contract and current limits,
see [harness compatibility](skills/mstack-run/references/harness-compatibility.md).

---

## How it works

### Skills

**User-facing:**

| Skill | Purpose |
|---|---|
| `/mstack-ideate` | Divergent idea exploration with trap detection, clustering, and structured handoff to plan-multi |
| `/mstack-plan-multi` | Decompose a goal into ordered plans with dependencies |
| `/mstack-plan-new` | Scaffold a single plan file |
| `/mstack-plan-doctor` | Validate plans, score readiness, audit test infrastructure |
| `/mstack-backlog` | Reprioritize, defer, drop, or stash plans |
| `/mstack-status` | Read-only dashboard: where are we, what's next |
| `/mstack-handoff` | Capture session state for a clean restart — output in chat or save a checkpoint to resume later |
| `/mstack-stash` | Park an unready idea for later |
| `/mstack-wrap-up` | Single end-of-session entry point: mine the session for scaffolding to delete, docs it made wrong, and learnings never written down, apply what you approve, render a verdict, then close this session or hand off the rest to a fresh one |
| `/mstack-init` | Bootstrap a project for mstack (runs automatically on first use) |
| `/mstack-config` | Project settings: health commands, weights, review providers |
| `/mstack-changelog` | Sync CHANGELOG.md with git history |

**Internal (run automatically during execution):**

| Skill | When | Purpose |
|---|---|---|
| `mstack-run` | Every plan | Pick, implement, verify, review, commit one plan |
| `mstack-code-health` | Every plan | Score health 0-10, track trends, detect regressions |
| `mstack-code-review` | Every plan | Behavior-preserving simplification, then 1 or 3 blind reviewers with cross-model routing |
| `mstack-investigate` | On failure | Category-aware debugging with strike rules |
| `mstack-learned-patterns` | Before and after | Apply relevant knowledge, extract new patterns |
| `mstack-checkpoint` | After each plan | Crash recovery state |

**Supporting references:**

| Reference | Purpose |
|---|---|
| `mstack-shared` | Shared cognitive frames for multi-perspective plan review and decomposition |

**Deprecated:**

| Skill | Status |
|---|---|
| `/mstack-simplify-code` | Merged into `/mstack-code-review` (Step 1b). The directory ships only a redirect stub, kept so existing routing and old invocations still resolve. Use `/mstack-code-review`. |

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
| `health.commands.*` | auto-detect | Override the command for a health category (`typecheck`, `lint`, `test`, `e2e`, `deadcode`, `shell`) |
| `health.weights.*` | see scoring table | Adjust category weights |
| `review.provider` | `auto` | External model: auto, codex, gemini, claude-only |
| `commit.conventional` | `true` | Write commit subjects as `type(scope): subject` |
| `commit.trailer` | `true` | Append a `Refs: <plans-dir>/<file>` trailer to each commit |
| `ignored_paths` | `[]` | Paths the worker is instructed never to edit (advisory: read by `mstack-run`, not enforced by a hook) |

The full schema, including which values each key accepts, lives in
`skills/mstack-config/SKILL.md`.

---

## gstack integration

mstack is designed to work with [gstack](https://github.com/AiCodeCraft/gstack), an AI-powered development toolkit that adds browser automation, QA testing, cross-model code review, and interactive plan review skills.

**mstack works without gstack**, but the experience is significantly richer with it:

| Capability | Without gstack | With gstack |
|---|---|---|
| **Plan reviews** | Built-in auto-decision framework | Interactive CEO, eng, and design review skills |
| **Code review** | Independent reviewers on the current harness | Cross-model routing (Codex, Gemini) for generator/judge separation |
| **QA & browser testing** | Manual | `/browse` for automated browser-based verification |
| **Plan design review** | Not available | Interactive `/plan-design-review` before implementation |

By default, `./setup` detects a local GStack checkout and installs only the
GStack skills MStack uses, plus their shared runtime assets:

```bash
./setup
```

This installs the `mstack` profile for every detected host: CEO, engineering,
and design plan reviews, plus `/browse` for `[browse]` verification. It does
not expose the rest of GStack's skill suite. If GStack is absent, setup logs a
skip and MStack remains fully usable; run it again after installing GStack. Set
`MSTACK_GSTACK_DIR` when your checkout lives outside Skillshare's default
location, or use `./setup --without-gstack` to skip the integration explicitly.

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

## Resilience during autonomous execution

When you close the laptop and `/goal` is running a scoped set of plans, three layers keep the run from going off the rails.

### Three-layer defense

**Layer 1 — Upfront validation.** Before any plan runs, every scoped plan ID is resolved to a file on disk. Typos, missing files, and duplicate IDs are caught immediately. The picker also detects dependency cycles. If validation fails, the goal stops before touching any code.

**Layer 2 — Execution manifest.** A manifest file (`.mstack/execution-manifest.json`) is created at the start of a scoped goal and updated after every plan iteration. It records which plans were requested, which file each plan maps to, which plans have reached a terminal state (done or failed), and a pick history. On each iteration the manifest re-resolves file paths and logs any divergence (e.g. a file was renamed or moved while execution was in progress).

**Layer 3 — Anomaly detection.** After each plan iteration, four anomaly checks run against the manifest:

| Anomaly | Trigger | What it means |
|---|---|---|
| `iteration_bound` | Iteration count exceeds scope size + 1 | The loop ran more times than there are plans — something is not terminating |
| `repeat_pick` | Same plan picked twice consecutively without becoming terminal | A plan keeps getting selected but never finishes |
| `no_progress` | Iteration completed but no new plans reached terminal state | Work ran but nothing actually got done |
| `path_divergence` | A non-terminal plan's file path changed since the manifest was created | Someone (or something) moved or renamed a plan file mid-run |

If any anomaly fires, execution stops and an automatic handoff checkpoint is saved to `.mstack/handoffs/`. The run prints the `[mstack] ANOMALY:` terminal signal plus the exact `resume from handoff anomaly-<type>` command. The execution manifest is preserved for debugging instead of being deleted.

### Enforcement: mstack installs git hooks in your repo

This one matters before you install, because it changes what `git commit` does in your repo.

`mstack-init` (and `./setup`) point your repo at a tracked hooks directory: `git config core.hooksPath .githooks`, plus a `pre-commit` and `pre-push` shim written into `.githooks/`. Any pre-existing hooks path is saved to `mstack.priorHooksPath` and chained, so a gitleaks scanner or whatever else you had keeps running.

What the hooks do: **reject a commit whose staged plan content flips a plan to `status: done` while its required reviews are missing**, or that weakens an already-recorded review state; and reject a push of a `mstack/plan-*-done` tag for a plan that is not completable. Ordinary commits are untouched. If the hook cannot find the mstack skill it fails open for normal work and closed only on a detected plan completion, so a broken install cannot brick your repo.

This is one layer of four, each firing at a different moment:

1. **Picker (convenience).** `pick-next.sh` skips plans with open reviews, so the honest loop rarely reaches a completion it cannot finish. Ergonomics, not enforcement.
2. **Completion gate (honest path).** Before writing `status: done`, `mstack-run` runs `review-gate.sh assert-completable` and `assert-no-downgrade`. This stops forgetting, not circumventing.
3. **Git hook (write barrier).** Fires regardless of how the commit was produced, including a hand-written `status: done`.
4. **Audit (retroactive backstop).** `review-gate.sh audit`, surfaced by `/mstack-status` and `/mstack-plan-doctor`, scans every done plan for a missing review record. This is what catches the two ways layer 3 can be evaded: `git commit --no-verify` and out-of-band edits.

**The honest residual.** Git hooks are local-only, are not cloned with the repo, and `--no-verify` bypasses them. Anyone with shell access can delete the hook. So this is **deterrent plus detectable**, not unbypassable, which is not achievable when the actor being gated is the same agent holding the shell. The audit is what turns "bypassable" into "a bypass leaves a trail the next status or doctor run surfaces."

To remove it: `git config --unset core.hooksPath` and delete `.githooks/`. The full model, including the fail-closed rules that must not be softened, lives in `AGENTS.md` under "Layered Enforcement Model".

### Exit codes

mstack's scripts use distinct exit codes so the caller knows exactly what happened rather than inferring it from stderr. The reserved range starting at 10 avoids collision with bash/system conventions (1 = general error, 2 = misuse, 126/127 = permission/not-found, 128+ = signals).

`skills/mstack-run/scripts/lib.sh` is the authoritative list; each constant is defined there with a comment explaining when it fires. The codes you are most likely to see:

**Plan picking (`pick-next.sh`)**

| Exit code | Constant | Meaning |
|---|---|---|
| 0 | `EXIT_PLAN_FOUND` | A plan was selected and is ready to execute |
| 10 | `EXIT_ALL_DONE` | All scoped plans have reached a terminal state |
| 11 | `EXIT_SCOPED_NOT_FOUND` | One or more requested plan IDs do not exist on disk |
| 12 | `EXIT_ALL_BLOCKED` | Remaining plans are blocked by unfinished dependencies |
| 13 | `EXIT_CYCLE` | A dependency cycle was detected in the plan graph |
| 14 | `EXIT_DUPLICATE_IDS` | Two or more plan files share the same `id` in their frontmatter |
| 15 | `EXIT_GOAL_NOT_FOUND` | A goal was named that no plan declares |

**Plan references by name**

| Exit code | Constant | Meaning |
|---|---|---|
| 21 | `EXIT_REF_AMBIGUOUS` | A plan name matched more than one plan; mstack aborts instead of guessing |
| 22 | `EXIT_REF_NOT_FOUND` | A plan name matched nothing |

**Completion and review gates (`review-gate.sh`, `result-gate.sh`)**

| Exit code | Constant | Meaning |
|---|---|---|
| 23 | `EXIT_GATE_NOT_COMPLETABLE` | The plan cannot legitimately be marked done |
| 24 | `EXIT_GATE_DOWNGRADE` | An edit weakened a plan's acceptance criteria or verification |
| 25 | `EXIT_GATE_NOT_COMMITTED` | A plan carries review records that were never committed |
| 26 | `EXIT_GATE_HOOK_MISSING` | `core.hooksPath` is unset, so the write barrier is not installed |
| 27 | `EXIT_GATE_AUDIT_FOUND` | A retroactive audit found a done plan that skipped its gate |
| 28 | `EXIT_GATE_WORK_UNCOMMITTED` | A plan was marked done with its own work still uncommitted |
| 30 | `EXIT_RESULT_HEALTH_INVALID` | A worker reported `pass` with health fields that do not parse |
| 32 | `EXIT_PLAN_SCAFFOLD` | The plan file is still an unedited scaffold |

**Health and verification**

| Exit code | Constant | Meaning |
|---|---|---|
| 29 | `EXIT_SCAN_NOT_GIT` | A scan target is not a git repository |
| 31 | `EXIT_HEALTH_NO_TOOLS` | Zero health tools detected and the repo never declared it has none |
| 33 | `EXIT_VERIFY_BROKEN` | A plan's declared verification check is itself broken |
| 34 | `EXIT_HEALTH_UNREACHABLE` | A test the plan adds exists but the health command does not run it |
| 36 | `EXIT_HEALTH_INTERNAL` | The gate could not score the repo for an mstack-side reason (unreadable weights, or a detected category with no weight) |

### The execution manifest

The manifest lives at `.mstack/execution-manifest.json` and is created when a scoped goal starts (e.g. `/goal complete mstack plans 008, 009, 010 via mstack-run orchestration`). It is deleted when all scoped plans reach a terminal state. The manifest contains:

- **`scope_ids`** — the plan IDs you requested
- **`plans`** — each plan ID mapped to its resolved file path
- **`picked_history`** — ordered list of which plans were picked on each iteration
- **`terminal_ids`** — plans that are done or failed
- **`path_diverged`** — plans whose file path changed since the manifest was created
- **`iteration_count`** — how many iterations have run
- **`created_at` / `updated_at`** — timestamps for staleness detection

If a session crashes and you start a new one, a stale manifest (updated > 1 hour ago) triggers a warning. The manifest is overwritten on the next scoped goal run — no manual cleanup needed.

### Troubleshooting

| Scenario | What happens | Recovery |
|---|---|---|
| Plan ID typo in `/goal` command | Upfront validation catches it (exit 11), refuses to start | Fix the ID and re-run |
| Plan file renamed during execution | Path divergence detected, anomaly handoff saved | Resume from handoff, check plan files |
| Plan stuck in-progress | Iteration bound or no-progress anomaly fires | Check plan status, re-run or mark failed |
| Dependency cycle | Picker exits 13, goal stops | Fix the cycle in plan frontmatter `blocked-by` fields |
| Stale manifest from crashed session | Warning logged on next run, overwritten | No action needed (auto-recovered) |
| Same plan picked repeatedly | `repeat_pick` anomaly fires, handoff saved | Check why the plan did not reach terminal state |

---

## License

MIT

## Optional Paperclip dashboard

Use `/mstack-config paperclip connect` once to select an instance, company and project.
Connected mstack authoring and execution automatically report human desktop/CLI
sessions; local plans, health and review gates remain authoritative. Unconfigured,
declined or disabled tracking keeps ordinary workflows local. Status, reconnect and
disable use `/mstack-config paperclip`; existing prototype users can follow
[the migration and rollback guide](docs/paperclip-migration.md). Paperclip hosting and
backups stay with your infrastructure configuration.
