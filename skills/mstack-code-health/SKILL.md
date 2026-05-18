---
name: mstack-code-health
description: |
  Run project checks (typecheck, lint, test, dead code, shell lint), score each
  0-10, compute a weighted composite, track trends in .mstack/health-history.jsonl,
  and detect regressions. Returns PASS / FAIL / REGRESSED verdict.

  Called by mstack-run automatically at Step 5. Also callable standalone
  for a read-only health dashboard.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

You run the project's verification tools, score quality, and track trends.
Unlike a binary pass/fail gate, you produce a composite score that catches
regressions even when tests pass ("you added 200 lines of dead code").

User input (optional):

```
$ARGUMENTS
```

## Hard rules

- **Wrap, don't replace.** Run the project's own tools. Never substitute
  your own analysis for what the tool reports.
- **Never fix issues.** When called standalone, produce the dashboard only.
  When called by mstack-run, return the verdict — the worker decides what
  to do with failures.
- **Skipped is not failed.** If a tool isn't available, skip it and
  redistribute its weight. Do not penalize the score.

## Discovery — check for enhanced scoring

Check if the gstack /health skill is installed:

```bash
[ -f ~/.config/skillshare/skills/health/SKILL.md ] && echo "GSTACK_HEALTH: available" || echo "GSTACK_HEALTH: unavailable"
```

If available, log it. The built-in logic below is the canonical implementation
either way — gstack /health is noted for the user's awareness, not delegated to.

## Step 1 — Detect health stack

Read `.mstack/config.json` for explicit health commands:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ -f "$REPO_ROOT/.mstack/config.json" ] && cat "$REPO_ROOT/.mstack/config.json" || echo "NO_CONFIG"
```

If config has a `health` section with explicit commands, use those.

Otherwise read CLAUDE.md for a `## Health Stack` section. If found, use those
commands.

Otherwise auto-detect:

```bash
# Type checker
[ -f tsconfig.json ] && echo "TYPECHECK: tsc --noEmit"
[ -f pyproject.toml ] && grep -q "mypy" pyproject.toml 2>/dev/null && echo "TYPECHECK: mypy ."
[ -f Cargo.toml ] && echo "TYPECHECK: cargo check"

# Linter
[ -f biome.json ] || [ -f biome.jsonc ] && echo "LINT: biome check ."
ls eslint.config.* .eslintrc.* .eslintrc 2>/dev/null | head -1 && echo "LINT: eslint ."
[ -f pyproject.toml ] && grep -q "ruff" pyproject.toml 2>/dev/null && echo "LINT: ruff check ."

# Test runner
[ -f package.json ] && grep -q '"test"' package.json 2>/dev/null && echo "TEST: pnpm test"
[ -f pyproject.toml ] && grep -q "pytest" pyproject.toml 2>/dev/null && echo "TEST: pytest"
[ -f Cargo.toml ] && echo "TEST: cargo test"
[ -f go.mod ] && echo "TEST: go test ./..."

# Dead code
command -v knip >/dev/null 2>&1 && echo "DEADCODE: knip"
[ -f package.json ] && grep -q '"knip"' package.json 2>/dev/null && echo "DEADCODE: npx knip"

# Shell linting
command -v shellcheck >/dev/null 2>&1 && echo "SHELL: shellcheck"
```

## Step 2 — Run tools

Run each detected tool sequentially. For each:

1. Record start time
2. Run the command, capturing stdout+stderr
3. Record exit code
4. Record end time
5. Capture the last 50 lines of output for reporting

If a tool is not installed or not found, record as `SKIPPED` with reason.

## Step 3 — Score each category

Score each category 0-10:

| Category   | Weight | 10          | 7            | 4             | 0              |
|------------|--------|-------------|--------------|---------------|----------------|
| Type check | 25%    | Clean       | <10 errors   | <50 errors    | >=50 errors    |
| Lint       | 20%    | Clean       | <5 warnings  | <20 warnings  | >=20 warnings  |
| Tests      | 30%    | All pass    | >95% pass    | >80% pass     | <=80% pass     |
| Dead code  | 15%    | Clean       | <5 unused    | <20 unused    | >=20 unused    |
| Shell lint | 10%    | Clean       | <5 issues    | >=5 issues    | N/A (skip)     |

**Parsing tool output for counts:**
- **tsc:** count lines matching `error TS`
- **biome/eslint/ruff:** count error/warning lines or parse the summary
- **Tests:** parse pass/fail counts from runner output. Exit 0 only = score 10,
  exit non-zero = score 4 (assume some failures)
- **knip:** count lines reporting unused exports/files/dependencies
- **shellcheck:** count distinct findings

**Composite score:**
```
composite = sum(category_score * weight) for active categories
```

If a category is skipped, redistribute its weight proportionally among the
remaining categories.

Override weights from `.mstack/config.json` `health.weights` if configured.

## Step 4 — Compare against previous entry

Read the last entry from `.mstack/health-history.jsonl`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
tail -1 "$REPO_ROOT/.mstack/health-history.jsonl" 2>/dev/null || echo "NO_HISTORY"
```

Determine verdict:
- **PASS**: composite >= 7.0 AND no category below 4
- **FAIL**: composite < 7.0 OR any category at 0
- **REGRESSED**: composite dropped by >= 1.0 from previous entry, OR any
  category dropped by >= 3 points, even if still above PASS threshold

## Step 5 — Persist to health history

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$REPO_ROOT/.mstack"
grep -q "^\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".mstack/" >> "$REPO_ROOT/.gitignore"
```

Append one JSONL line to `$REPO_ROOT/.mstack/health-history.jsonl`:

```json
{"ts":"2026-05-19T14:30:00Z","branch":"main","plan_id":"042","score":9.1,"typecheck":10,"lint":8,"test":10,"deadcode":7,"shell":10,"duration_s":23}
```

Set `plan_id` to the current plan ID if called from mstack-run, or `null`
if called standalone.

## Step 6 — Present dashboard

When called standalone, present a full dashboard:

```
CODE HEALTH DASHBOARD
=====================

Project: <project name>
Branch:  <current branch>
Date:    <today>

Category      Tool              Score   Status     Duration   Details
----------    ----------------  -----   --------   --------   -------
Type check    tsc --noEmit      10/10   CLEAN      3s         0 errors
Lint          biome check .      8/10   WARNING    2s         3 warnings
Tests         pnpm test         10/10   CLEAN      12s        47/47 passed
Dead code     knip               7/10   WARNING    5s         4 unused exports
Shell lint    shellcheck        10/10   CLEAN      1s         0 issues

COMPOSITE SCORE: 9.1 / 10
VERDICT: PASS

Duration: 23s total
```

Status labels: 10=CLEAN, 7-9=WARNING, 4-6=NEEDS WORK, 0-3=CRITICAL

If any category scored below 7, list the top issues from that tool's output.

## Step 7 — Trend analysis (standalone only)

Read the last 10 entries from health history and show the trend:

```
HEALTH TREND (last 5 runs)
==========================
Date          Branch    Plan    Score
----------    -------   -----   -----
2026-05-16    main      038     9.4
2026-05-17    main      039     8.8
2026-05-18    main      040     8.2
2026-05-19    main      042     9.1

Trend: IMPROVING (+0.9 since last run)
```

If score dropped, identify which categories declined and correlate with
tool output.

## Integration with mstack-run

When called by the worker, return a structured result the worker can act on:

```
HEALTH VERDICT: <PASS|FAIL|REGRESSED>
COMPOSITE: <score>
FAILURES: <list of categories that failed, or "none">
```

The worker interprets this:
- PASS: proceed to review (Step 6)
- FAIL or REGRESSED: enter mstack-investigate flow
