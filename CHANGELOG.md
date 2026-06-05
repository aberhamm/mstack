# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] - 2026-06-05

### Added
- **Handoff checkpoints**: `/mstack-handoff` now offers "Save handoff checkpoint" alongside chat output. Checkpoints save to `.mstack/handoffs/` and you resume in a new session with `resume from handoff <name>` — no copy-paste needed. Files auto-delete on resume and auto-prune after 7 days
- **Completed plan auto-archiving**: finished plans automatically move to `docs/plans/archive/`, keeping the active backlog clean
- **Resilient plan execution**: three-layer defense for autonomous runs — upfront validation, execution manifest tracking, and anomaly detection with auto-handoff (plans 016-019):
  - **Distinct picker exit codes** (plan 016): `pick-next.sh` returns structured exit codes (10-14) for all-done, scoped-not-found, all-blocked, dependency-cycle, and duplicate-IDs, replacing generic error codes
  - **Execution manifest** (plan 017): `.mstack/execution-manifest.json` tracks scoped goal state across iterations — scope IDs, file path resolution, pick history, terminal states, and path divergence detection
  - **Anomaly detection** (plan 018): four anomaly checks (iteration bound, repeat pick, no progress, path divergence) fire after each iteration and halt the run before damage compounds
  - **Auto-handoff on anomaly** (plan 019): when an anomaly is detected, a handoff checkpoint is saved automatically so you can resume in a fresh session with `resume from handoff`

### Changed
- **Progressive disclosure for skills**: mstack-run (1,350→895 lines), plan-doctor (1,119→845 lines), plan-multi (504→305 lines), and mstack-ideate (409→251 lines) now load large conditional sections from `references/` on demand instead of holding everything inline. Reduces always-loaded context without losing capability
- Handoff now asks to commit uncommitted changes *before* generating the handoff document, so the summary reflects the actual repo state

### Fixed
- Cognitive frames path resolution now works correctly via skillshare
- Handoff no longer auto-starts work when loaded as context
- Deduplicated learnings search results across multiple queries in mstack-run

<!-- commits: 175d7ae, 28a7af5, 2be0c2e, aadea1b, e12c42b, e39cb82, f06e220, be1f9d8, 5e1aade, 0d50120, 054ae2c, 0159c29, 1e8db8f, 4604236, 04b3ddc -->

## [Unreleased] - 2026-06-03

### Added
- **`/mstack-ideate`**: brainstorm before committing to plans. Takes a problem statement, runs 3-5 isolated reasoning branches under different cognitive frames, scores ideas on novelty/viability/fit, and presents a ranked list with a "non-obvious pick" and provocation. Includes trap detection, clustering by approach angle, and structured handoff to `/mstack-plan-multi`
- **Cognitive frames library**: 11 reusable prompt blocks (8 review + 3 decomposition) that give plan-doctor, plan-multi, and mstack-ideate distinct evaluation perspectives (security, performance, SRE, end user, adversarial, cost, simplicity, maintainability, plus decomposition frames for coupling, parallelism, and simplicity)
- **Multi-frame review in plan-doctor**: each plan is now reviewed through 3 deterministically-selected cognitive frames. Critical findings deduct from autonomy-readiness; advisory findings are non-blocking. Auto-fix resolves addressable gaps
- **Trap resistance scoring**: 5th scoring dimension in plan-doctor (0-10). Detects premature abstractions, false economies, hidden coupling, won't-scale patterns, and scope creep magnets using an adversarial evaluation prompt. Plans below 4/10 get auto-fixed
- **Divergent decomposition in plan-multi**: choose "Explore" to generate 3 competing plan breakdowns from different angles (minimize coupling, maximize parallelism, simplest-thing-that-works), score them, and reconcile the winner. "Direct" preserves existing single-pass behavior
- **Stack-aware testing recommendations**: on first init, mstack detects your project stack and framework, runs a 5-tier testing audit, shows a confidence path (LOW/MEDIUM/HIGH), and optionally searches the web for stack-specific best practices. Offers to scaffold a testing plan as plan 001
- **Progress output during goal execution**: `[mstack]` prefixed status lines show which plan is running, health gate results, review findings, and commit messages. Tree-drawing characters show pipeline stage
- **Final cross-plan validation**: after all plans complete, runs a full-suite health check to catch regressions between plans, with git blame attribution for failures
- **Post-plan cleanup sweep**: scans files touched by the current plan for unused imports, dead functions, debug statements, and orphan files before code review
- **Pre-handoff artifact check**: mstack-handoff now scans for leftover temp files (*.tmp, *.bak, debug-*) before generating the handoff summary
- **Scoped plan execution**: pass specific plan IDs to `/mstack-run` or `/goal` (e.g., `/goal complete mstack plans 008, 009, 010, 011`) instead of "all pending". Plan-multi and plan-new now output scoped run commands
- **`[browse]` verification checks**: plans touching web-facing code can include `[browse]` checks that invoke gstack's headless browser for real E2E verification
- `/mstack-stash`: save unresolved conversation threads for later without committing to a formal plan
- `/mstack-backlog`: interactive backlog grooming with reprioritize, defer, drop, stash
- **Testing infrastructure audit**: plan-doctor now scans for 5 tiers of testing (static analysis, unit, integration, E2E/browser, API contracts) and reports walk-away confidence (HIGH/MEDIUM/LOW) with recommendations
- **E2E in health gate**: auto-detects Playwright, Cypress, and `test:e2e` scripts. Runs them as a scored category (20% default weight) alongside typecheck/lint/test

### Changed
- **Composite score formula**: plan-doctor now uses explicit weights (clarity 20%, testability 25%, scope-fit 20%, autonomy 25%, trap resistance 10%), configurable via `.mstack/config.json` key `health.weights.planning`
- **Testability scoring tightened**: plans with only grep/test-f verification checks are capped at 5/10 on testability. Web-facing plans missing E2E checks are flagged as errors
- **Plan-multi generates testing approach**: each generated plan now includes a "Testing approach" line (unit-only, E2E, or browser-based) in its Design section
- **Multi-model structural critique**: plan-multi now routes decompositions through Codex and Sonnet for independent structural review before finalizing
- **Status dashboard**: shows cold-start context for fresh sessions picking up mid-backlog
- **Adversarial code review mode**: add `review: adversarial` to plan frontmatter for a standard reviewer plus an adversarial reviewer hunting production failure modes
- Renamed `plan-backlog` to `plan-multi` for clarity
- Auto-update check wired into skill preambles
- **Mandatory verification**: plans without executable verification checks (`[cmd]`, `[assert]`, `[status]`) are now blocked by plan-doctor. Add `verification: health-only` to frontmatter for purely visual plans
- **Removed supervised mode**: the `autonomy` config/frontmatter field is gone. Execution is always fully autonomous; the plan is the contract
- **Learnings feed plan-doctor**: pitfalls and dependencies from previous executions now surface during plan validation, so the architect can adjust the design before walking away
- **Plan-doctor hardened**: posture selector retained (the architect controls scope strategy), but auto-fixes plans below 8/10 on autonomy-readiness without asking, auto-generates verification checks, auto-resets stale in-progress plans
- **Category-aware strike rule**: investigation now allows 3 strikes per distinct root cause category (max 3 categories = 9 total attempts), replacing the flat 3-strike limit
- **Configurable review depth**: default is 1 unified reviewer; add `review: thorough` to plan frontmatter for 3 blind reviewers with cross-model routing
- **Skill consolidation**: merged `mstack-simplify-code` into `mstack-code-review` (Step 4b); marked `mstack-checkpoint` as internal; marked `mstack-changelog` as utility
- **`/goal` owns the loop**: removed `loop.max_iterations` config and iteration counter. mstack-run does one plan per invocation; `/goal` decides when to stop
- Backlog execution uses Claude Code's native `/goal` command instead of `/loop`

### Fixed
- Worktree cleanup now runs at mstack-run startup and after each plan
- Dependency chain wiring for plans that modify the same skill file sequentially

<!-- commits: 292b084, 83ab19f, 2b7442f, c31475f, 99538cb, 49122e0, 0b97940, 10c7584, 43280d3, c1c1713, 90c5a26, 64bfa70, c9ee80d, c99e189, 76eaaeb, f00657b, 76476d2, a779977, 3fca88d, f04c36a, 10e4c15, caaf2b1, ae46543 -->

## [2.0.0] - 2026-05-20

### Added
- You can now decompose any goal into an ordered plan backlog with `/mstack-plan-multi`, or just say "create a plan for X" in natural language
- Plans are validated, scored on 4 dimensions (Clarity, Testability, Scope-fit, Autonomy-readiness), and reviewed with configurable postures (Expand, Selective, Hold, Reduce) via `/mstack-plan-doctor`
- Full autonomous execution loop: `/loop /mstack-run` picks plans, implements them, runs health checks, reviews code, commits, and moves to the next plan
- Health scoring system (0-10 composite across typecheck, lint, tests, dead code, shell lint) with regression detection and trend tracking
- Cross-model code review with blind scoring that routes one reviewer through Codex or Gemini when available
- Structured debugging with a hard 3-strike rule when health checks fail, with no infinite retry loops
- Crash recovery via checkpoints: if a session dies mid-plan, the next session resumes from facts, not stale reasoning
- Self-healing learnings knowledge base that prunes stale patterns and applies relevant knowledge to future plans
- Three autonomy levels (`full`, `checkpoint`, `supervised`) configurable globally or per-plan (removed in Unreleased)
- Auto-initialization on first use, with no manual setup step required
- Project configuration via `.mstack/config.json` for health commands, scoring weights, review providers, commit conventions, and ignored paths
- Read-only status dashboard (`/mstack-status`) showing backlog state, health trends, and session stats
- 8 bash scripts backing the skill layer for deterministic state operations (bash 3.2 compatible, macOS + Linux)
- Dual install support: `skillshare install aberhamm/mstack` or manual copy to `~/.claude/skills/`

<!-- commits: aa7896e, a08f3ef, 386cab8, 2f17c09, b28441a, 349811e, ca6d6f4, f273bb5, 6a8db20, fc80809, bd333a7, 1959e6f, 2ddcad3, f68aa77, 0211c1f -->
