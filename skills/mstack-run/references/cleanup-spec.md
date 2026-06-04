# Step 5c: Cleanup sweep

After the verification gate passes, run a targeted cleanup sweep on only
the files created or modified by the current plan. This catches artifacts
that slip through during implementation before they reach code review.

## Get changed files

Collect the list of files this plan touched:

```bash
# Files changed since the recovery point (includes claim commit + uncommitted work)
git diff --name-only ${RECOVERY} HEAD
git diff --name-only HEAD
```

Combine both lists (deduplicated). This is the scope of the sweep; never
check files outside this set.

## Check for artifacts

For each changed file, scan for:

1. **Unused imports**: `import`/`require` statements where the imported
   name does not appear elsewhere in the file. Use grep-level heuristics,
   not AST analysis.

2. **Dead functions**: functions or classes defined in the file that are
   not called anywhere within the changed files or imported by other
   files in the diff.

3. **Debug artifacts**: `console.log`, `debugger` statements, `TODO`,
   `FIXME`, `HACK` comments that were added during implementation (not
   pre-existing). Compare against the recovery point to distinguish new
   from existing:
   ```bash
   git diff ${RECOVERY} -- <file> | grep '^+' | grep -E 'console\.log|debugger|TODO|FIXME|HACK'
   ```

4. **Orphan files**: new files (present in CREATED list) that are not
   imported or referenced by any other file in the project:
   ```bash
   grep -rl "<filename>" . --include='*.ts' --include='*.js' --include='*.md' | grep -v <the file itself>
   ```

## Act on findings

- **Issues found**: fix them in the working tree, then re-run the health
  gate to confirm no regressions:
  ```bash
  PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
  ```
  If the health gate passes after cleanup, proceed to Step 6.
  If it fails, revert the cleanup fixes and proceed to Step 6 with the
  original passing implementation.

- **No issues**: proceed directly to Step 6.

## Progress output

```
[mstack] ├─ Cleanup: removed 2 unused imports, 1 debug statement
```
or:
```
[mstack] ├─ Cleanup: nothing to clean
```
