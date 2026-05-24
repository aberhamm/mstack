# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — 2026-05-25

### Added
- `/mstack-stash` — save unresolved conversation threads for later without committing to a formal plan. List, save, resume, delete. Shows up in `/mstack-status` dashboard under a "STASHED" heading.
- `/mstack-backlog` — interactive backlog grooming. View all plans in priority order, then reprioritize, defer, drop, or stash plans without leaving the conversation.

### Changed
- Backlog execution now uses Claude Code's native `/goal` command instead of `/loop` + ScheduleWakeup. The new kickoff: `/goal all pending mstack plans are done or failed`
- `mstack-run` remains a single-iteration tool — `/goal`'s evaluator (Haiku) decides whether to continue based on the status line output

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
- Three autonomy levels (`full`, `checkpoint`, `supervised`) configurable globally or per-plan
- Configurable iteration cap for loop runs (`loop.max_iterations`, default 5, set to 0 for unlimited)
- Auto-initialization on first use — no manual setup step required
- Project configuration via `.mstack/config.json` for health commands, scoring weights, review providers, commit conventions, and ignored paths
- Read-only status dashboard (`/mstack-status`) showing backlog state, health trends, and session stats
- 8 bash scripts backing the skill layer for deterministic state operations (bash 3.2 compatible, macOS + Linux)
- Dual install support: `skillshare install aberhamm/mstack` or manual copy to `~/.claude/skills/`

<!-- commits: aa7896e, a08f3ef, 386cab8, 2f17c09, b28441a, 349811e, ca6d6f4, f273bb5, 6a8db20, fc80809, bd333a7, 1959e6f, 2ddcad3, f68aa77, 0211c1f -->
