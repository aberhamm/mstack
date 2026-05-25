# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — 2026-05-25

### Added
- `/mstack-stash` — save unresolved conversation threads for later without committing to a formal plan
- `/mstack-backlog` — interactive backlog grooming with reprioritize, defer, drop, stash

### Changed — "Human = architect, AI = builder" overhaul
- **Mandatory verification**: plans without executable verification checks (`[cmd]`, `[assert]`, `[status]`) are now blocked by plan-doctor. Add `verification: health-only` to frontmatter for purely visual plans
- **Removed supervised mode**: the `autonomy` config/frontmatter field is gone. Execution is always fully autonomous — the plan is the contract
- **Learnings feed plan-doctor**: pitfalls and dependencies from previous executions now surface during plan validation, so the architect can adjust the design before walking away
- **Plan-doctor hardened**: posture selector retained (the architect controls scope strategy), but auto-fixes plans below 8/10 on autonomy-readiness without asking, auto-generates verification checks, auto-resets stale in-progress plans
- **Category-aware strike rule**: investigation now allows 3 strikes per distinct root cause category (max 3 categories = 9 total attempts), replacing the flat 3-strike limit
- **Configurable review depth**: default is 1 unified reviewer; add `review: thorough` to plan frontmatter for 3 blind reviewers with cross-model routing
- **Skill consolidation**: merged `mstack-simplify-code` into `mstack-code-review` (Step 4b); marked `mstack-checkpoint` as internal; marked `mstack-changelog` as utility
- Backlog execution uses Claude Code's native `/goal` command instead of `/loop`

## [2.0.0] — 2026-05-20

### Added
- You can now decompose any goal into an ordered plan backlog with `/mstack-plan-backlog` — or just say "create a plan for X" in natural language
- Plans are validated, scored on 4 dimensions (Clarity, Testability, Scope-fit, Autonomy-readiness), and reviewed with configurable postures (Expand, Selective, Hold, Reduce) via `/mstack-plan-doctor`
- Full autonomous execution loop: `/loop /mstack-run` picks plans, implements them, runs health checks, reviews code, commits, and moves to the next plan
- Health scoring system (0-10 composite across typecheck, lint, tests, dead code, shell lint) with regression detection and trend tracking
- Cross-model code review with blind scoring — routes one reviewer through Codex or Gemini when available
- Structured debugging with a hard 3-strike rule when health checks fail — no infinite retry loops
- Crash recovery via checkpoints: if a session dies mid-plan, the next session resumes from facts, not stale reasoning
- Self-healing learnings knowledge base that prunes stale patterns and applies relevant knowledge to future plans
- Three autonomy levels (`full`, `checkpoint`, `supervised`) configurable globally or per-plan (removed in Unreleased)
- Auto-initialization on first use — no manual setup step required
- Project configuration via `.mstack/config.json` for health commands, scoring weights, review providers, commit conventions, and ignored paths
- Read-only status dashboard (`/mstack-status`) showing backlog state, health trends, and session stats
- 8 bash scripts backing the skill layer for deterministic state operations (bash 3.2 compatible, macOS + Linux)
- Dual install support: `skillshare install aberhamm/mstack` or manual copy to `~/.claude/skills/`

<!-- commits: aa7896e, a08f3ef, 386cab8, 2f17c09, b28441a, 349811e, ca6d6f4, f273bb5, 6a8db20, fc80809, bd333a7, 1959e6f, 2ddcad3, f68aa77, 0211c1f -->
