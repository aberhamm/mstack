---
id: 7
title: Add stack-aware testing recommendations to mstack-init
status: pending
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-05-30
---

## Requirements

When a developer sets up mstack in a new project, mstack-init bootstraps the
directory structure but says nothing about the project's testing infrastructure.
The developer then creates plans, runs plan-doctor, and gets a walk-away confidence
level — but by that point, the right time to invest in testing setup has passed.

This plan adds a testing infrastructure audit to mstack-init's first-run flow.
On first init, mstack detects the project's stack and version, uses web search
to look up current testing best practices for that specific stack, diffs the
community recommendations against what already exists, and offers to scaffold
a testing infrastructure plan as the first plan in the backlog. The goal: give
the architect maximum comfort before they even start planning features.

**Acceptance criteria:**

- [ ] mstack-init Step 2 (after bootstrap) detects the project type (web app, API server, CLI tool, library, monorepo) from config files (package.json, pyproject.toml, Cargo.toml, go.mod, etc.) and identifies the primary framework and version (e.g., "Next.js 15.2", "FastAPI 0.115", "Rails 8.0")
- [ ] mstack-init runs the existing 5-tier testing infrastructure audit (same detection logic as plan-doctor Step 0b) and reports what exists
- [ ] When confidence is MEDIUM or LOW, mstack-init runs a web search for current testing best practices for the detected stack (e.g., "Next.js 15 testing best practices 2026")
- [ ] Search results are synthesized into 2-4 concrete, stack-specific recommendations with install commands (not generic advice like "add tests")
- [ ] Recommendations diff against what already exists — never recommend something the project already has
- [ ] The output includes a "confidence path" showing what the project needs to reach HIGH confidence (e.g., "MEDIUM → HIGH: add Playwright E2E tests")
- [ ] When gaps are found, mstack-init offers via AskUserQuestion: "Want to start with a testing infrastructure plan? (Recommended — sets up your test suite before any feature plans.)"
- [ ] If the user accepts, a plan file is scaffolded as plan 001 in `docs/plans/` with the recommended testing setup
- [ ] If web search is unavailable (no WebSearch tool, network error), falls back gracefully to the existing hardcoded tier-based recommendations with a note: "(recommendations based on built-in heuristics — web search unavailable)"
- [ ] When confidence is already HIGH, print a congratulatory note and skip recommendations: "Walk-away confidence: HIGH. Your testing infrastructure is solid."
- [ ] The audit only runs on fresh init (not reinit or auto-init guard), to avoid latency on every skill invocation
- [ ] The stack detection result and confidence level are persisted to `.mstack/config.json` so plan-doctor can display them without re-detecting

## Design

This modifies `skills/mstack-init/SKILL.md` to add a testing infrastructure
audit after the bootstrap step. It also saves detection results to
`.mstack/config.json` so plan-doctor can reference them.

**Files expected to change:**

- `skills/mstack-init/SKILL.md` — add stack detection, testing audit, web search recommendations, confidence path, and scaffold offer after Step 2

**Approach:**

**New Step 2b — Stack detection and testing audit** (after existing Step 2, before Step 3):

Only runs on fresh init (not `ALREADY_INITIALIZED`).

```
1. Detect stack:
   - Read package.json → framework + version from dependencies
   - Read pyproject.toml / requirements.txt → Python framework + version
   - Read Cargo.toml → Rust framework
   - Read go.mod → Go framework
   - Classify: web-app, api-server, cli-tool, library, monorepo
   - Output: "Detected: Next.js 15.2 web application"

2. Run 5-tier testing audit (same logic as plan-doctor Step 0b):
   - Tier 1: Static analysis (tsc, mypy, cargo check, linters)
   - Tier 2: Unit tests (test runner + actual test files)
   - Tier 3: Integration tests (test containers, API test files)
   - Tier 4: E2E / Browser (Playwright, Cypress, Selenium)
   - Tier 5: API contracts (OpenAPI, Pact)
   - Compute confidence: HIGH / MEDIUM / LOW

3. If confidence < HIGH:
   - Search: "<framework> <version> testing best practices <current year>"
   - Read top 2-3 results for detail
   - Synthesize 2-4 concrete recommendations with install commands
   - Show confidence path: "MEDIUM → HIGH: add Playwright E2E tests"

4. If confidence < HIGH and recommendations exist:
   - Ask: "Want to start with a testing infrastructure plan?"
   - If yes: scaffold plan 001 with the recommended setup
   - If no: proceed, print "You can add testing later with /mstack-plan-new"

5. Save to .mstack/config.json:
   - stack.type: "web-app"
   - stack.framework: "next"
   - stack.version: "15.2"
   - stack.confidence: "MEDIUM"
   - stack.detected_at: "2026-05-30"
```

**Plan-doctor integration (no code change needed):**

Plan-doctor's Step 0b already runs the 5-tier audit independently. The config.json
values let it display "Detected stack: Next.js 15.2 (from init)" as context, but
plan-doctor does not need modification — it already computes confidence on its own
from live detection.

**Scaffold behavior (simpler than the original plan 007 approach):**

When the user accepts the scaffold offer, write a single plan file as plan 001.
No blocked-by rewriting needed — it's the first plan in a fresh project. If plans
already exist (reinit scenario), skip the scaffold offer entirely.

**Fallback behavior:**

- WebSearch unavailable → use tier-based heuristics, note the limitation
- Search returns nothing useful → same fallback
- Project type undetectable → skip stack-specific search, use tier-based audit only
- Already initialized → skip the entire audit (no latency on auto-init)

**Out of scope:**

- Changing plan-doctor's Step 0b (it stays as-is)
- Changing the 5-tier detection definitions or confidence thresholds
- Auto-installing any testing tools
- Changes to mstack-code-health or health-check.sh
- Running the audit on reinit or auto-init guard invocations

## Tasks

1. Add `AskUserQuestion` and `WebSearch` and `WebFetch` to mstack-init's `allowed-tools` in frontmatter
2. Add "Step 2b — Stack detection and testing audit" section after Step 2 in SKILL.md — detect project type and framework from config files, run the 5-tier testing audit, compute confidence level
3. Add web search logic: construct query from detected stack, run WebSearch + WebFetch, synthesize into concrete recommendations with install commands; include fallback for when web search is unavailable
4. Add confidence path output format showing current level and what's needed for the next level
5. Add scaffold offer via AskUserQuestion — if accepted, write a plan 001 file with the recommended testing setup; only offer on fresh init when no plans exist yet
6. Save stack detection results and confidence level to `.mstack/config.json`
7. Gate the entire Step 2b behind fresh-init check (skip when `ALREADY_INITIALIZED` or auto-init guard)

## Verification

- [assert] grep -i 'stack detection\|project type\|detected:' skills/mstack-init/SKILL.md
- [assert] grep -i 'WebSearch\|web search' skills/mstack-init/SKILL.md
- [assert] grep -i 'confidence path\|MEDIUM.*HIGH\|confidence.*level' skills/mstack-init/SKILL.md
- [assert] grep -i 'scaffold\|testing infrastructure plan\|plan 001' skills/mstack-init/SKILL.md
- [assert] grep 'WebSearch' skills/mstack-init/SKILL.md | head -1
- [assert] grep -i 'fallback\|unavailable\|heuristic' skills/mstack-init/SKILL.md
- [assert] grep -i 'AskUserQuestion' skills/mstack-init/SKILL.md
