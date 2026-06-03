---
name: mstack-init
description: |
  Bootstrap a project for mstack. Creates docs/plans/, .mstack/ with
  config and gitignore entries, optionally detects health tools and
  appends them to CLAUDE.md. Idempotent; safe to call repeatedly.

  Called automatically by mstack-plan-multi, mstack-plan-doctor,
  mstack-run, and mstack-status when .mstack/ doesn't exist. Also
  callable directly to set up a project explicitly.
argument-hint: "[--with-claude-md]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
  - WebSearch
  - WebFetch
---

You bootstrap a project for mstack. This is idempotent; running it on
an already-initialized project does nothing harmful.

User input (optional):

```
$ARGUMENTS
```

## Step 1: Resolve paths and check state

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
```

Check if already initialized:

```bash
[ -d "$REPO_ROOT/.mstack" ] && echo "ALREADY_INITIALIZED" || echo "NEEDS_INIT"
```

If `ALREADY_INITIALIZED` and the user didn't invoke this skill directly
(i.e., called from another skill's auto-init guard), exit silently.

If `ALREADY_INITIALIZED` and invoked directly, show the current state
and offer to reinitialize.

## Step 2: Run bootstrap

```bash
bash "$SKILL_DIR/scripts/init.sh" bootstrap
```

If the user passed `--with-claude-md`:

```bash
bash "$SKILL_DIR/scripts/init.sh" bootstrap --with-claude-md
```

This creates:
- `docs/plans/` (or detects existing `plans/`)
- `.mstack/` directory
- `.mstack/config.json` with defaults
- `.mstack/` and `.mstack-*` added to `.gitignore`
- (Optional) `## Health Stack` section appended to CLAUDE.md

## Step 2b: Stack detection and testing audit

**Gate:** Only run this step on fresh init. If `ALREADY_INITIALIZED` (from Step 1),
or if this was triggered by the auto-init guard from another skill, skip this
entire step and proceed to Step 3.

### 2b.1: Detect project type

Scan the repo root for config files to identify the project stack:

```bash
cd "$REPO_ROOT"
# Detect config files
[ -f package.json ] && echo "HAS_PACKAGE_JSON"
[ -f pyproject.toml ] && echo "HAS_PYPROJECT_TOML"
[ -f requirements.txt ] && echo "HAS_REQUIREMENTS_TXT"
[ -f Cargo.toml ] && echo "HAS_CARGO_TOML"
[ -f go.mod ] && echo "HAS_GO_MOD"
```

Read the detected config file(s) to identify framework and version:

- **package.json**: Check `dependencies` and `devDependencies` for framework
  (next, react, vue, angular, express, fastify, nest, etc.) and its version.
- **pyproject.toml / requirements.txt**: Check for framework (django, flask,
  fastapi, etc.) and its version.
- **Cargo.toml**: Check `[dependencies]` for framework (actix-web, axum,
  rocket, etc.) and its version.
- **go.mod**: Check `require` for framework (gin, echo, fiber, etc.) and its
  version.

Classify the project type:
- **web-app**: Has a frontend framework (Next.js, React, Vue, Angular, SvelteKit)
- **api-server**: Has a backend framework (Express, FastAPI, Django, Rails, Gin)
- **cli-tool**: Has a `bin` field in package.json, or a `[tool.poetry.scripts]`
  section, or a `[[bin]]` in Cargo.toml
- **library**: Has no server/app entry point, publishes to a registry
- **monorepo**: Has `workspaces` in package.json, or `pnpm-workspace.yaml`,
  or multiple `Cargo.toml` files

Print the detection result:

```
Detected: <framework> <version> <project-type>
```

**Fallback:** If the project type is undetectable (no recognized config files),
print "Could not detect project stack. Skipping stack-specific recommendations."
and skip to saving minimal results in 2b.6.

### 2b.2: Run 5-tier testing audit

Scan the project for existing testing infrastructure across five tiers:

**Tier 1 - Static analysis** (catches bugs without running code):
- TypeScript: check for `tsconfig.json` and `tsc --noEmit` capability
- Python: check for `mypy` in pyproject.toml or dev dependencies
- Rust: `cargo check` is built-in
- Linter: check for eslint, biome, ruff, pylint, clippy config or dependencies

**Tier 2 - Unit tests** (fast, isolated, catch logic bugs):
- Check for test runner in dependencies (jest, vitest, pytest, cargo test, go test)
- Check for actual test files (`**/*.test.*`, `**/*.spec.*`, `tests/`, `test/`)
- Both the runner AND test files must exist to count as present

**Tier 3 - Integration tests** (components working together):
- Database test utilities: test containers, in-memory DBs, fixtures
- API test files: `*.integration.test.*`, `*.spec.*` with HTTP calls
- Check for `test:integration` or `test:e2e` scripts in package.json

**Tier 4 - E2E / Browser tests** (full user flows):
- Playwright: `playwright.config.*` or `@playwright/test` in dependencies
- Cypress: `cypress.config.*` or `cypress/` directory
- Selenium/WebDriver: `selenium` in dependencies
- Check for `test:e2e`, `test:playwright`, `test:cypress` scripts

**Tier 5 - API contract tests** (external boundaries):
- OpenAPI/Swagger specs: `openapi.yaml`, `swagger.json`
- Contract testing: `pact` in dependencies
- API test collections: `*.http`, `*.rest`, Postman/Insomnia exports

Compute confidence level:
- **HIGH**: Tiers 1-2 present + at least one of Tiers 3-5
- **MEDIUM**: Tiers 1-2 present, Tiers 3-5 all missing
- **LOW**: Missing Tier 1 or Tier 2

Print a summary table:

```
Testing infrastructure audit:
  Tier 1 (static analysis):   [FOUND] / [MISSING]
  Tier 2 (unit tests):        [FOUND] / [MISSING]
  Tier 3 (integration tests): [FOUND] / [MISSING]
  Tier 4 (E2E / browser):     [FOUND] / [MISSING]
  Tier 5 (API contracts):     [FOUND] / [MISSING]

Walk-away confidence: <HIGH|MEDIUM|LOW>
```

### 2b.3: Recommendations (when confidence < HIGH)

If confidence is **HIGH**, print:

```
Walk-away confidence: HIGH. Your testing infrastructure is solid.
```

Then skip to 2b.6 (save results).

If confidence is **MEDIUM** or **LOW**, show built-in recommendations first.
These are deterministic and require no network access:

For each missing tier, provide a curated recommendation based on the detected
stack. Examples:

- Missing Tier 1 (TypeScript project): "Add `tsc --noEmit` to your CI. Run:
  ensure `strict: true` in tsconfig.json."
- Missing Tier 2 (Next.js): "Add Vitest for unit tests. Run: `npm install -D
  vitest @testing-library/react`"
- Missing Tier 4 (web-app): "Add Playwright for E2E tests. Run: `npm init
  playwright@latest`"

Show the confidence path -- what the project needs to reach the next level:

```
Confidence path: MEDIUM -> HIGH: add Playwright E2E tests (Tier 4)
```

or

```
Confidence path: LOW -> MEDIUM: add TypeScript strict mode (Tier 1) + Vitest unit tests (Tier 2)
```

Then ask the user if they want web search for more specific recommendations:

```
AskUserQuestion: "Want to search the web for more specific recommendations for your <framework> <version> stack?"
```

**If the user says yes:**

Use ToolSearch with query `select:WebSearch,WebFetch` to load the WebSearch and
WebFetch tools before calling them. These are deferred tools that must be loaded
via ToolSearch first.

Then search for current best practices:

```
WebSearch: "<framework> <version> testing best practices <current year>"
```

Read the top 2-3 results with WebFetch, then synthesize 2-4 concrete,
stack-specific recommendations with install commands. Diff against what already
exists in the project; never recommend something the project already has.

Append web-sourced recommendations after the built-in ones.

**If the user says no, or if WebSearch/WebFetch are unavailable:**

Proceed with built-in recommendations only. Print:

```
(recommendations based on built-in heuristics; web search unavailable)
```

**Fallback:** If ToolSearch fails to load WebSearch/WebFetch, or if the web
search returns no useful results, or if any error occurs during web search,
fall back gracefully to built-in recommendations only with the note above.
Never let a web search failure block initialization.

### 2b.4: Scaffold offer (when confidence < HIGH)

If confidence is less than HIGH and recommendations were generated:

```
AskUserQuestion: "Want to start with a testing infrastructure plan? (Recommended: sets up your test suite before any feature plans.)"
```

**If the user says yes:**

Scaffold a plan file at `docs/plans/001-testing-infrastructure.md` (or the
detected plans directory) with:

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

<generated from the recommendations above -- both built-in and web-sourced>

## Design

**Files expected to change:**
<inferred from recommendations, e.g., package.json, playwright.config.ts, vitest.config.ts>

**Out of scope:**
- Application feature changes (this plan only sets up testing tools)

## Tasks

<numbered steps from recommendations, e.g.:
1. Install Playwright: npm init playwright@latest
2. Create playwright.config.ts with base configuration
3. Add test:e2e script to package.json>

## Verification

<generated checks, e.g.:
- [cmd] npx playwright test --list
- [assert] test -f playwright.config.ts
- [cmd] npx vitest --run>
```

Only offer the scaffold on fresh init when no plan files exist yet in the plans
directory. If plans already exist (reinit scenario), skip the scaffold offer.

**If the user says no:**

Print: "You can add testing later with /mstack-plan-new"

### 2b.5: Fallback summary

All failure modes and their behavior:

| Scenario | Behavior |
|---|---|
| Project type undetectable | Skip stack-specific recs, run tier-based audit only |
| WebSearch/WebFetch unavailable | Proceed with built-in recommendations, note "(web search unavailable)" |
| Web search returns no results | Proceed with built-in recommendations, note "(web search returned no results)" |
| ToolSearch fails to load tools | Proceed with built-in recommendations, note "(web search unavailable)" |
| Network error during search | Proceed with built-in recommendations, note "(web search unavailable)" |
| User declines web search | Proceed with built-in recommendations only |
| User declines scaffold | Print guidance about /mstack-plan-new |
| Already initialized | Skip entire Step 2b |
| Auto-init guard invocation | Skip entire Step 2b |
| AskUserQuestion unavailable | Skip interactive prompts, use built-in recommendations only |

### 2b.6: Persist detection results

Save the detection results to `.mstack/config.json` so plan-doctor and other
skills can reference them without re-detecting. Read the existing config.json
first, merge the new values, and write back:

```json
{
  "stack": {
    "type": "<web-app|api-server|cli-tool|library|monorepo|unknown>",
    "framework": "<next|react|fastapi|django|express|etc.>",
    "version": "<detected version string>",
    "confidence": "<HIGH|MEDIUM|LOW>",
    "detected_at": "<ISO date>"
  }
}
```

Use Read to load existing config.json, merge the `stack` key into the existing
object (preserving other keys), and Write the result back.

If the stack was undetectable, save:

```json
{
  "stack": {
    "type": "unknown",
    "framework": "unknown",
    "version": "unknown",
    "confidence": "LOW",
    "detected_at": "<ISO date>"
  }
}
```

## Step 3: First-run guidance

If this is a fresh init (not already initialized), print:

```
mstack is ready. Three commands to know:

  /mstack-plan-multi "your goal"     Decompose a goal into ordered plans
  /mstack-plan-doctor                Validate and review the backlog
  /goal all pending mstack plans are done or failed   Execute autonomously

Everything else (health checks, code review, debugging, crash recovery)
runs automatically inside the loop. You don't need to call those directly.

Optional: run /mstack-config show to see project settings.
```

## Auto-init guard (for other skills to use)

Other mstack skills should include this guard near the top of their
execution flow:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

This ensures every mstack skill checks for updates (cached, once per hour)
and works on first use without requiring the user to run init manually.
