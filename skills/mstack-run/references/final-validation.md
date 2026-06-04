# Final Validation Pass

After all plans have been executed (or failed/skipped) and before the
simplify pass, run a full-codebase health gate to catch cross-plan
regressions. This uses the same health-check.sh but without a PLAN_ID,
so it checks everything rather than scoping to one plan's changes.

Print:
```
[mstack] Final validation: running full test suite...
```

Run:
```bash
bash "$SKILL_DIR/scripts/health-check.sh" run
```

(Note: no PLAN_ID env var set, so the script runs against the full codebase.)

Parse the VERDICT and COMPOSITE. Print the result:

- On PASS:
  ```
  [mstack] Final validation: <COMPOSITE>/10 (PASS)
  ```

- On FAIL:
  ```
  [mstack] Final validation: FAILED (<which categories failed with their scores>)
  ```

  If the final validation fails, identify which specific tests/checks
  failed from the health output. Then use `git blame` on the failing
  lines to attribute the regression to a specific plan commit:

  ```bash
  git blame <failing file> | grep -E "<plan commit hashes>"
  ```

  Cross-reference plan commit hashes (from `git log --oneline` looking
  for `chore(plan N)` or `feat(...)` commits from this session) to
  identify the likely source plan. Print:

  ```
  [mstack] WARNING: Cross-plan regression detected.
  [mstack]   <category> failures: <details>
  [mstack]   likely source: plan <id> (commit <hash>) modified <file>
  [mstack]   Review the failures above before pushing.
  ```

  If `git blame` cannot isolate the regression to a single plan, report
  the failures without attribution.

  **Final validation failure does NOT mark any plan as failed.** Each
  plan passed its individual health gate. The regression is a cross-plan
  interaction that the user must review. Do not auto-fix.
