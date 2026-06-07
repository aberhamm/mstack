# Step 5b: Verification gate (feature correctness)

After the health gate passes, verify the plan's acceptance criteria are
actually met by executing the checks in the `## Verification` section.

## Parse the Verification section

Read the plan file's `## Verification` section. Extract lines matching:
- `[cmd] <command>`: run the command, assert exit code 0
- `[assert] <command> | <expected>`: run the command, assert stdout contains the expected string
- `[status] <curl command> -> <code>`: run the curl, assert HTTP status matches
- `[browse] <url-or-path> <assertion>`: browser-based check via gstack's /browse skill
- `[manual] <description>`: log as skipped (human review only)

If no executable checks exist (section empty, all `[manual]`, or only
template placeholder `- ...`):
- If the plan has `verification: health-only` in frontmatter: skip this
  step, proceed to Step 5c. Log: "verification: health-only, skipping
  feature checks per architect override."
- Otherwise: this should not happen (plan-doctor blocks plans without
  verification). Treat as a failure; the plan spec is incomplete.
  Set `failed-reason: missing-verification-checks` and go to Step 7b.

## Execute checks

For each executable check (30-second timeout per check):

```bash
mkdir -p "$REPO_ROOT/.mstack/evidence/plan-${PLAN_ID}"
```

**`[cmd]`**: Run the command. Pass if exit code is 0.

**`[assert]`**: Run the command before the `|`. Check if stdout contains
the string after `|` (trimmed). Pass if found.

**`[status]`**: Run the curl command. Extract the HTTP status code. Pass
if it matches the expected code after `→`.

**`[browse]`**: Browser-based check execution via gstack's /browse skill.
Format: `[browse] <url-or-path> <assertion>` where the assertion is a
natural language description of what to verify (e.g.,
`[browse] /settings/billing verify 'Current Plan' heading is visible`).

**[browse] check execution steps:**

1. **Detect gstack installation:** Check if the browse skill is available:
   ```bash
   test -f "${HOME}/.config/skillshare/skills/browse/SKILL.md" || \
   test -f "${HOME}/.config/skillshare/skills/gstack/browse/SKILL.md" || \
   test -f "${HOME}/.agents/skills/browse/SKILL.md" || \
   test -f "${HOME}/.agents/skills/gstack/browse/SKILL.md" || \
   test -f "${HOME}/.codex/skills/browse/SKILL.md" || \
   test -f "${HOME}/.codex/skills/gstack/browse/SKILL.md" || \
   test -f "${HOME}/.claude/skills/browse/SKILL.md" || \
   test -f "${HOME}/.claude/skills/gstack/browse/SKILL.md"
   ```

2. **If gstack not installed:** Skip all `[browse]` checks with a warning:
   ```
   Skipped [browse] check: gstack not installed. Install gstack for browser-based verification.
   ```
   Record the check as `SKIPPED` in the evidence directory. `[browse]`
   skips do not count as failures; treat them like `[manual]` checks.

3. **If gstack is installed:** Ensure the dev server is running before
   executing any `[browse]` checks:
   - Read `AGENTS.md` first and `CLAUDE.md` if present for the project's
     start command (e.g., `npm run dev`, `pnpm dev`). If not found, check
     `package.json` for a `"dev"` or `"start"` script.
   - If the dev server is not already running, start it in the background.
   - Wait for the server to become ready: poll the health endpoint or
     check the port (retry up to 15s with 1s intervals).
   - If the server fails to start within 15s, skip `[browse]` checks with
     a warning: "Dev server failed to start. Skipping [browse] checks."

4. **For each `[browse]` check:**
   - Parse the check line: extract `<path>` and `<assertion>`.
   - Invoke the `/browse` skill with instructions to navigate to the path
     and verify the assertion (natural language).
   - Pass if the browse skill confirms the assertion is met.
   - Fail if the browse skill reports the assertion is not met or errors.
   - Record the result to `.mstack/evidence/plan-${PLAN_ID}/check-N.txt`.

5. **After all `[browse]` checks complete:** Stop the dev server if this
   step started it (do not stop a server that was already running).

`[browse]` check failures are treated the same as `[cmd]` failures: the
plan enters investigation with the same 3-strike category-aware rule.

For checks that require a running server (including `[status]` and `[cmd]`
checks that hit endpoints): read `AGENTS.md` first and `CLAUDE.md` if present
for the start command, start it in the background, wait for readiness (retry
the health endpoint up to 10s), run checks, then stop it.

Record each result to `.mstack/evidence/plan-${PLAN_ID}/check-N.txt`:
```
PASS | [cmd] npm run test:e2e -- --grep rate-limit | exit 0
```
or:
```
FAIL | [status] curl -sw '%{http_code}' localhost:3000/api/users → 500 (expected 200)
OUTPUT: {"error":"not_initialized"}
```

## Write summary

After all checks complete, write `.mstack/evidence/plan-${PLAN_ID}/summary.md`:

```markdown
# Verification: plan-${PLAN_ID}

N/M checks passed

| # | Type   | Check                     | Result |
|---|--------|---------------------------|--------|
| 1 | cmd    | npm run test:e2e ...      | PASS   |
| 2 | assert | curl ... \| grep ok       | PASS   |
| 3 | manual | Check login page renders  | SKIPPED |

Failed output:
  (only if any failures; include the first 500 chars of stdout/stderr)
```

## Act on results

- **All executable checks PASS** → proceed to Step 5c
- **Any check FAIL** → enter investigation (same 3-strike rule as Step 5).
  The investigation context includes which check failed and its output.
  After 3 strikes: Step 7 failure path with
  `failed-reason: "verification: <check description>"`
- **All checks skipped/manual** → proceed to Step 5c (no evidence written)

## Update qa: field

Track what verification level was achieved for the commit trailer:
- Health gate only (no executable checks) → `qa: automated`
- Health gate + verification checks passed → `qa: automated,verified`
