---
name: mstack-simplify-code
description: |
  DEPRECATED: merged into mstack-code-review (Step 4b). This skill is kept
  for backward compatibility but redirects to code-review. Use
  /mstack-code-review instead.
argument-hint: "[<scope: file path, commit range, or 'branch'>]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
---

You are simplifying recently changed code. Your job: find opportunities to
make the code clearer, more reusable, and more consistent with project
conventions, then apply the changes and verify nothing broke.

User input (optional scope):

```
$ARGUMENTS
```

## Hard rules

- **Never change behavior.** Tests must pass identically before and after.
- **Never add abstractions speculatively.** Only consolidate when there are
  2+ concrete instances of the same logic already in the codebase.
- **Clarity over brevity.** Three clear lines beat one clever line.
- **Respect existing patterns.** If the project uses X style, don't introduce Y.
- **Run the gate.** If you can't verify, don't commit.
- **Comment the WHY, not the WHAT.** Add comments where the intent isn't
  obvious from the code itself. Prefer single-line comments. Use multiline
  only when the explanation genuinely requires it (e.g., documenting a
  workaround for a specific bug, explaining a non-obvious algorithm choice,
  or clarifying a business rule that can't be inferred from context).

## Step 1: Determine scope

Resolve what code to analyze:

- **No argument**: use `git diff HEAD~1 --name-only` (last commit's files)
- **File path**: analyze that specific file
- **Commit range** (e.g., `HEAD~3..HEAD`): use `git diff <range> --name-only`
- **`branch`**: use `git diff $(git merge-base main HEAD)..HEAD --name-only`

If the diff is empty, check for uncommitted changes with `git diff --name-only`
and `git diff --cached --name-only`. If still empty: "Nothing to simplify."

Print the file list and total lines changed:

```
Scope: last commit (abc1234)
Files: 4 changed (+120, -45)
  src/api/handlers.ts
  src/lib/utils.ts
  src/components/UserCard.tsx
  tests/api/handlers.test.ts
```

## Step 2: Read project conventions

Read `CLAUDE.md` from the repo root (and any nested ones closer to the changed
files). Extract:

- Language and framework conventions
- Naming patterns
- Import style
- Error handling approach
- Test conventions
- Any explicit "do not" rules

If no CLAUDE.md exists, infer conventions from the surrounding code (read 2-3
sibling files to the changed ones for style reference).

## Step 3: Analyze each changed file

For each file in scope, read it fully and check for:

### 3a. Reuse opportunities

Search the codebase for:
- **Duplicate logic**: grep for similar patterns in other files. If the same
  3+ line block exists elsewhere, it's a candidate for extraction.
- **Existing utilities**: check `lib/`, `utils/`, `helpers/`, `shared/` dirs
  for functions that already do what the new code does inline.
- **Standard library**: flag cases where a language/framework built-in could
  replace a manual implementation.

### 3b. Clarity issues

- Unnecessary nesting (early returns could flatten)
- Overly generic names (`data`, `result`, `temp`, `handler`)
- Dead code (unreachable branches, unused variables, commented-out blocks)
- Redundant type assertions or casts
- Copy-paste with minor variations (candidate for parameterization)
- Magic numbers/strings without context
- **Missing comments where intent is non-obvious**: hidden constraints,
  workarounds for specific bugs, subtle invariants, business rules that
  can't be inferred from surrounding code, or "why not the obvious approach"
  decisions. Add a single-line comment above the relevant code. Use multiline
  block comments only when the explanation needs multiple sentences (e.g.,
  referencing an external issue, documenting a protocol quirk, or explaining
  a performance-critical ordering constraint).
- **Stale or misleading comments**: comments that describe WHAT the code does
  (redundant with well-named identifiers), reference removed code, or
  contradict the current implementation. Remove these.

### 3c. Consistency with project conventions

- Import ordering/style doesn't match siblings
- Naming convention violations (camelCase vs snake_case, etc.)
- Error handling pattern differs from rest of codebase
- File/function structure doesn't match similar files

### 3d. Efficiency

- Obvious N+1 patterns (loop with await inside that could be batched)
- Unnecessary re-computation (same expensive call in a loop)
- Missing early exits (processing continues after answer is known)
- Allocations in hot paths that could be hoisted

## Step 4: Report findings

Print a summary before making changes:

```
Findings: 3 issues in 2 files

src/api/handlers.ts:
  REUSE    Lines 45-52 duplicate parseUserInput() from src/lib/parse.ts
  CLARITY  Lines 80-95 nested 4 levels deep, could flatten with early returns

src/components/UserCard.tsx:
  CONSISTENCY  Uses arrow function export, rest of components/ uses function keyword
```

If no issues found: "Code looks clean. No simplification needed." and stop.

## Step 5: Apply fixes

For each finding, edit the file. Apply changes surgically; don't rewrite
entire files. For reuse opportunities, import the existing utility rather
than creating a new abstraction.

Track every file modified.

## Step 6: Verification gate

Run the project's checks:

```bash
# Read test/lint/typecheck commands from CLAUDE.md, or fall back to:
pnpm -r typecheck 2>/dev/null || npx tsc --noEmit 2>/dev/null || true
pnpm -r lint 2>/dev/null || npx eslint . 2>/dev/null || true
pnpm test 2>/dev/null || npm test 2>/dev/null || pytest 2>/dev/null || cargo test 2>/dev/null || go test ./... 2>/dev/null || true
```

Use the commands from CLAUDE.md if they differ.

If gate fails:
- If the failure is clearly caused by your changes, revert and report what
  went wrong. Do not retry more than once.
- If the failure is pre-existing (was already failing before your changes),
  note it and proceed.

## Step 7: Summary

Print a before/after summary:

```
Simplified 2 files:

src/api/handlers.ts:
  - Replaced inline parsing (8 lines) with existing parseUserInput()
  - Flattened nested conditionals with early returns (-12 lines)

src/components/UserCard.tsx:
  - Converted arrow export to function keyword (project convention)

Gate: ✅ typecheck pass, lint pass, tests pass (14 specs)
Net: -20 lines, +1 import, 0 new abstractions
```

If invoked after `mstack-run` (detectable by checking if the last
commit message contains `Refs: docs/plans/`), end with:

```
Post-plan simplification complete. Review with: git diff HEAD~2..HEAD
```
