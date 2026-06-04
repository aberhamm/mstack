# Step 0b: Testing Infrastructure Audit

Before validating individual plans, audit what testing infrastructure the
project has. mstack is as good as your test suite, and this step tells the
architect exactly how much walk-away confidence they can expect.

### Detection

Scan the project for testing tools across 5 tiers:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
```

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

### Output

Print a testing infrastructure report:

```
TESTING INFRASTRUCTURE
══════════════════════════════════════════════════════════
  Tier 1, Static analysis     ✅ TypeScript (tsc), Biome
  Tier 2, Unit tests          ✅ Vitest (47 test files)
  Tier 3, Integration tests   ⚠️  no integration test scripts detected
  Tier 4, E2E / Browser       ✅ Playwright (playwright.config.ts)
  Tier 5, API contracts       ⚠️  no contract tests detected

Walk-away confidence: HIGH
  The health gate will run: typecheck, lint, unit tests, Playwright E2E
  Not covered: integration tests between services, API contract verification
```

**Confidence levels:**
- **HIGH**: Tiers 1-2 present + at least one of Tiers 3-5
- **MEDIUM**: Tiers 1-2 present, Tiers 3-5 missing
- **LOW**: Missing Tier 1 or Tier 2

For MEDIUM or LOW, print specific recommendations:

```
RECOMMENDATIONS (to increase walk-away confidence):
  - Add Playwright for browser testing: npm init playwright@latest
  - Add a test:e2e script to package.json
  - Add integration tests for database operations (your plans touch db/ files)
```

These are recommendations, not blockers. The architect decides how much
testing infrastructure to invest in. But they should know what they're
getting. mstack will use everything available, and skip what's not there.

### Health gate integration

If Tier 3+ tools are detected, add them to the health gate. Tell the
architect what the health gate will actually run during execution:

```
Health gate will run during execution:
  typecheck  → npx tsc --noEmit
  lint       → npx biome check .
  test       → npm test
  e2e        → npx playwright test
  deadcode   → npx knip
```

Then proceed to validation.
