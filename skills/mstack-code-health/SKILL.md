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

## Scripts

All detection, scoring, persistence, and trending logic lives in
`health-check.sh`. Resolve the scripts directory:

```bash
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
[ -d "$SCRIPTS_DIR" ] || SCRIPTS_DIR="${HOME}/.claude/skills/mstack-run/scripts"
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/health-check.sh" detect` | List detected tools (`category:command` per line) |
| `bash "$SCRIPTS_DIR/health-check.sh" run` | Run all tools, score, persist to history, output verdict |
| `PLAN_ID=042 bash "$SCRIPTS_DIR/health-check.sh" run` | Same, tagged with a plan ID in the history |
| `bash "$SCRIPTS_DIR/health-check.sh" trend` | Output last 10 health-history JSONL entries |
| `bash "$SCRIPTS_DIR/health-check.sh" trend 5` | Output last N entries |

### Output format (`run`)

The `run` command prints structured key-value lines to stdout:

```
VERDICT:PASS
COMPOSITE:9.1
TYPECHECK:10
LINT:8
TEST:10
DEADCODE:7
SHELL:10
DURATION:23
FAILURES:none
```

Parse these to build the dashboard or return to mstack-run.

The script also persists one JSONL line to `.mstack/health-history.jsonl`
automatically — you do not need to write history yourself. The file is
rotated to keep only the last 100 entries.

## Standalone mode

When the user invokes `/mstack-code-health` directly:

1. Run `bash "$SCRIPTS_DIR/health-check.sh" run` and parse the output.

2. Present the dashboard:

```
CODE HEALTH DASHBOARD
=====================

Project: <project name>
Branch:  <current branch>
Date:    <today>

Category      Score   Status     Details
----------    -----   --------   -------
Type check    10/10   CLEAN      0 errors
Lint           8/10   WARNING    3 warnings
Tests         10/10   CLEAN      47/47 passed
Dead code      7/10   WARNING    4 unused exports
Shell lint    10/10   CLEAN      0 issues

COMPOSITE SCORE: 9.1 / 10
VERDICT: PASS
```

Status labels: 10=CLEAN, 7-9=WARNING, 4-6=NEEDS WORK, 0-3=CRITICAL

3. Run `bash "$SCRIPTS_DIR/health-check.sh" trend` and show the trend:

```
HEALTH TREND (last 5 runs)
==========================
Date          Branch    Plan    Score
<parsed from JSONL entries>

Trend: IMPROVING (+0.9 since last run)
```

If score dropped, identify which categories declined by comparing the
JSONL entries.

## Integration with mstack-run

When called by the worker, run:

```bash
PLAN_ID="$PLAN_ID" bash "$SCRIPTS_DIR/health-check.sh" run
```

Return the VERDICT line to the worker. The worker interprets:
- **PASS** → proceed to review (Step 6)
- **FAIL** or **REGRESSED** → enter mstack-investigate flow

## Scoring reference

The script uses these thresholds (for your reference when presenting results):

| Category   | Weight | 10          | 7            | 4             | 0              |
|------------|--------|-------------|--------------|---------------|----------------|
| Type check | 25%    | Clean       | <10 errors   | <50 errors    | >=50 errors    |
| Lint       | 20%    | Clean       | <5 warnings  | <20 warnings  | >=20 warnings  |
| Tests      | 30%    | All pass    | >95% pass    | >80% pass     | <=80% pass     |
| Dead code  | 15%    | Clean       | <5 unused    | <20 unused    | >=20 unused    |
| Shell lint | 10%    | Clean       | <5 issues    | >=5 issues    | N/A (skip)     |

Weights are overridable via `.mstack/config.json` `health.weights`.
Tools are discovered from config, then CLAUDE.md `## Health Stack`, then auto-detected.
