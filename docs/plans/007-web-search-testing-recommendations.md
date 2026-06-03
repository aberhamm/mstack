---
id: 7
title: Add stack-aware testing recommendations to mstack-init
status: in-progress
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-05-30
---

## Requirements

When a developer sets up mstack in a new project, mstack-init bootstraps the
directory structure but says nothing about the project's testing infrastructure.
The developer then creates plans, runs plan-doctor, and gets a walk-away confidence
level, but by that point the right time to invest in testing setup has passed.

This plan adds a testing infrastructure audit to mstack-init's first-run flow.
On first init, mstack detects the project's stack and version, uses web search
to look up current testing best practices for that specific stack, diffs the
community recommendations against what already exists, and offers to scaffold
a testing infrastructure plan as the first plan in the backlog. The goal: give
the architect maximum comfort before they even start planning features.

**Acceptance criteria:**

- [ ] mstack-init Step 2 (after bootstrap) detects the project type (web app, API server, CLI tool, library, monorepo) from config files (package.json, pyproject.toml, Cargo.toml, go.mod, etc.) and identifies the primary framework and version (e.g., "Next.js 15.2", "FastAPI 0.115", "Rails 8.0")
- [ ] mstack-init runs the existing 5-tier testing infrastructure audit (same detection logic as plan-doctor Step 0b) and reports what exists
- [ ] When confidence is MEDIUM or LOW, mstack-init first presents curated built-in recommendations based on the detected stack (fast, deterministic, no network)
- [ ] After showing built-in recommendations, mstack-init offers via AskUserQuestion: "Want to search the web for more specific recommendations for your stack?" (opt-in, not automatic)
- [ ] If the user accepts, runs a web search for current testing best practices for the detected stack (e.g., "Next.js 15 testing best practices 2026") and synthesizes 2-4 concrete, stack-specific recommendations with install commands
- [ ] Recommendations (both built-in and web-sourced) diff against what already exists; never recommend something the project already has
- [ ] The output includes a "confidence path" showing what the project needs to reach HIGH confidence (e.g., "MEDIUM → HIGH: add Playwright E2E tests")
- [ ] When gaps are found, mstack-init offers via AskUserQuestion: "Want to start with a testing infrastructure plan? (Recommended: sets up your test suite before any feature plans.)"
- [ ] If the user accepts, a plan file is scaffolded as plan 001 in `docs/plans/` with the recommended testing setup
- [ ] If the user declines web search, or if web search is unavailable (no WebSearch tool, network error), proceeds with built-in recommendations only, with a note: "(recommendations based on built-in heuristics)"
- [ ] When confidence is already HIGH, print a congratulatory note and skip recommendations: "Walk-away confidence: HIGH. Your testing infrastructure is solid."
- [ ] The audit only runs on fresh init (not reinit or auto-init guard), to avoid latency on every skill invocation
- [ ] The stack detection result and confidence level are persisted to `.mstack/config.json` so plan-doctor can display them without re-detecting

## Design

This modifies `skills/mstack-init/SKILL.md` to add a testing infrastructure
audit after the bootstrap step. It also saves detection results to
`.mstack/config.json` so plan-doctor can reference them.

**Files expected to change:**

- `skills/mstack-init/SKILL.md`: add stack detection, testing audit, web search recommendations, confidence path, and scaffold offer after Step 2

**Approach:**

**New Step 2b: Stack detection and testing audit** (after existing Step 2, before Step 3):

Only runs on fresh init (not `ALREADY_INITIALIZED`).

```
1. Detect stack:
   - Read package.json → framework + version from dependencies
   - Read pyproject.toml / requirements.txt → Python framework + version
   - Read Cargo.toml → Rust framework
   - Read go.mod → Go framework
   - Classify: web-app, api-server, cli-tool, library, monorepo
   - Output: "Detected: Next.js 15.2 web application"

2. Run 5-tier testing audit:

   **Tier 1, Static analysis** (catches bugs without running code):
   - TypeScript: `tsconfig.json` → `tsc --noEmit`
   - Python: `mypy` in pyproject.toml → `mypy .`
   - Rust: `Cargo.toml` → `cargo check`
   - Linter: eslint, biome, ruff, etc.

   **Tier 2, Unit tests** (fast, isolated, catch logic bugs):
   - `npm test` / `pytest` / `cargo test` / `go test`
   - Check: does the test runner exist AND are there actual test files?

   **Tier 3, Integration tests** (components working together):
   - Database test utilities: test containers, in-memory DBs, fixtures
   - API test files: `*.integration.test.*`, `*.spec.*` with HTTP calls
   - Check `package.json` for `test:integration`, `test:e2e` scripts

   **Tier 4, E2E / Browser tests** (full user flows):
   - Playwright: `playwright.config.*` or `@playwright/test` in dependencies
   - Cypress: `cypress.config.*` or `cypress/` directory
   - Selenium/WebDriver: `selenium` in dependencies
   - Check for `test:e2e`, `test:playwright`, `test:cypress` scripts

   **Tier 5, API contract tests** (external boundaries):
   - OpenAPI/Swagger specs: `openapi.yaml`, `swagger.json`
   - Contract testing: `pact` in dependencies
   - API test collections: `*.http`, `*.rest`, Postman/Insomnia exports

   **Confidence levels:**
   - **HIGH**: Tiers 1-2 present + at least one of Tiers 3-5
   - **MEDIUM**: Tiers 1-2 present, Tiers 3-5 missing
   - **LOW**: Missing Tier 1 or Tier 2

3. If confidence < HIGH:
   - Show curated built-in recommendations for the detected stack (deterministic, no network)
   - Show confidence path: "MEDIUM → HIGH: add Playwright E2E tests"
   - Ask via AskUserQuestion: "Want to search the web for more specific recommendations for your stack?"
   - If yes: search "<framework> <version> testing best practices <current year>", read top 2-3 results, synthesize 2-4 concrete stack-specific recommendations with install commands, append to built-in recommendations
   - If no (or web search unavailable): proceed with built-in recommendations only

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
plan-doctor does not need modification; it already computes confidence on its own
from live detection.

**Scaffold behavior (simpler than the original plan 007 approach):**

When the user accepts the scaffold offer, write a single plan file as plan 001.
No blocked-by rewriting needed; it's the first plan in a fresh project. If plans
already exist (reinit scenario), skip the scaffold offer entirely.

Template for the generated plan file:

```yaml
---
id: 1
title: Set up testing infrastructure
status: pending
blocked-by: []
needs-review: none
created: <today's date>
---

## Requirements

<generated from web search recommendations>

## Design

**Files expected to change:**
<inferred from recommendations, e.g., package.json, playwright.config.ts>

**Out of scope:**
- Application feature changes (this plan only sets up testing tools)

## Tasks

<numbered steps from recommendations, e.g., "1. Install Playwright", "2. Create config">

## Verification

<generated checks, e.g., [cmd] npx playwright test, [assert] test -f playwright.config.ts>
```

**Fallback behavior:**

- User declines web search → proceed with built-in recommendations only
- WebSearch unavailable or returns nothing useful → proceed with built-in recommendations, note: "(web search unavailable)"
- Project type undetectable → skip stack-specific recommendations, use tier-based audit only
- Already initialized → skip the entire audit (no latency on auto-init)
- WebSearch and WebFetch are deferred tools. The SKILL.md instructions should tell the executing agent to use ToolSearch to load them before calling. Example: `Use ToolSearch with query 'select:WebSearch,WebFetch' to load these tools before calling them.`

**Out of scope:**

- Changing plan-doctor's Step 0b (it stays as-is)
- Changing the 5-tier detection definitions or confidence thresholds
- Auto-installing any testing tools
- Changes to mstack-code-health or health-check.sh
- Running the audit on reinit or auto-init guard invocations

## Tasks

1. Add `AskUserQuestion` and `WebSearch` and `WebFetch` to mstack-init's `allowed-tools` in frontmatter
2. Add "Step 2b: Stack detection and testing audit" section after Step 2 in SKILL.md; detect project type and framework from config files, run the 5-tier testing audit, compute confidence level
3. Add web search logic: construct query from detected stack, run WebSearch + WebFetch, synthesize into concrete recommendations with install commands; include fallback for when web search is unavailable
4. Add confidence path output format showing current level and what's needed for the next level
5. Add scaffold offer via AskUserQuestion; if accepted, write a plan 001 file with the recommended testing setup; only offer on fresh init when no plans exist yet
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
- [assert] grep -i 'ToolSearch\|select:WebSearch' skills/mstack-init/SKILL.md
- [assert] grep -i 'stack\.type\|stack\.framework\|config\.json' skills/mstack-init/SKILL.md
