---
id: 016
title: Distinct exit codes for pick-next.sh
status: in-progress
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-06-05
---

## Requirements

pick-next.sh currently returns an empty string for both "all plans done" and
"plan not found." This ambiguity causes the /goal loop to misclassify a broken
scoped run as normal completion or keep retrying indefinitely when a plan ID
doesn't exist.

The picker must return distinct exit codes so callers can differentiate between
success, completion, and specific failure modes.

**Acceptance criteria:**

- [ ] pick-next.sh exits 0 with plan path on stdout when a plan is found
- [ ] pick-next.sh exits 10 when all plans (or all scoped plans) are done
- [ ] pick-next.sh exits 11 when a scoped ID has no matching plan file in plans/ or archive/
- [ ] pick-next.sh exits 12 when all remaining scoped plans are blocked by out-of-scope dependencies
- [ ] pick-next.sh exits 13 when a dependency cycle is detected among candidates
- [ ] pick-next.sh exits 14 when duplicate plan IDs are found across plan files
- [ ] Each non-zero exit writes a one-line diagnostic to stderr (e.g., "scoped ID 016 not found")
- [ ] lib.sh exports named constants for exit codes (EXIT_PLAN_FOUND=0, EXIT_ALL_DONE=10, etc.)
- [ ] SKILL.md Step 2 updated to handle each exit code with appropriate behavior
- [ ] Backward compatible: unscoped runs still work identically

## Design

Exit codes use the 10-19 range to avoid collision with bash/system codes (1=general
error, 2=misuse, 126/127=permission/not-found, 128+=signals).

**Exit code contract:**

| Code | Meaning | Stdout | Stderr |
|------|---------|--------|--------|
| 0 | Plan found | Plan file path | (empty) |
| 10 | All done | (empty) | "all plans done" or "all scoped plans done" |
| 11 | Scoped ID not found | (empty) | "scoped ID NNN not found in plans/ or archive/" |
| 12 | All blocked | (empty) | "N scoped plans blocked by out-of-scope deps: ..." |
| 13 | Dependency cycle | (empty) | "dependency cycle: A -> B -> A" |
| 14 | Duplicate IDs | (empty) | "duplicate plan ID NNN in: file1.md, file2.md" |

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next.sh`: replace final `exit 0` with specific exit codes, add duplicate ID detection
- `skills/mstack-run/scripts/lib.sh`: add EXIT_* constants section
- `skills/mstack-run/SKILL.md`: update Step 2 to check `$?` after picker call and handle each code

**Exit code priority ordering:** When multiple failure conditions overlap,
check in severity order: 14 (duplicates) > 11 (missing ID) > 13 (cycle) >
12 (blocked) > 10 (all done). Most specific/actionable failure surfaces first.

**SKILL.md capture pattern:** Use temp file pattern to preserve exit code
under pipefail: `bash ... > tmpfile; PICKER_EXIT=$?; NEXT=$(cat tmpfile)`.
Do NOT use `NEXT=$(bash ...)` which discards the exit code.

**Out of scope:** Execution manifest, iteration bounds, auto-handoff. Those are
plans 017-019. Also out of scope: "already picked but not terminal" detection
(requires manifest history from plan 017/018).

Testing approach: unit-only

## Tasks

1. Add EXIT_* constants to lib.sh (EXIT_PLAN_FOUND=0, EXIT_ALL_DONE=10, EXIT_SCOPED_NOT_FOUND=11, EXIT_ALL_BLOCKED=12, EXIT_CYCLE=13, EXIT_DUPLICATE_IDS=14)
2. Refactor pick-next.sh end-of-script: replace the current `[ -n "$best_path" ] && echo "$best_path"` with explicit exit code logic — if best_path found exit 0, else determine which specific failure condition applies
3. Add scoped-ID-not-found detection: when SCOPE_FILTER is set, verify each scoped ID has at least one matching plan file; exit 11 for the first missing ID
4. Add duplicate ID detection: scan all plan files for frontmatter `id:` values, exit 14 if any ID appears in multiple files
5. Change cycle detection from warning-only to exit 13 when cycles involve candidate plans (candidates = scoped + pending, or all non-done plans when unscoped)
6. Add all-blocked detection: when no candidate is runnable but scoped IDs exist that aren't done, exit 12
7. Update SKILL.md Step 2 to use temp file capture pattern: write picker stdout to a temp file, capture `$?` as PICKER_EXIT, then read the temp file into NEXT. Replace the current `NEXT=$(bash ...)` block. Branch on PICKER_EXIT: 0=proceed with NEXT, 10=report done and exit, 11-14=report specific error from stderr and exit iteration. Clean up temp file after use

## Verification

Checks:
- [assert] bash -c 'source skills/mstack-run/scripts/lib.sh; echo $EXIT_ALL_DONE' | grep "10"
- [assert] bash -c 'source skills/mstack-run/scripts/lib.sh; echo $EXIT_SCOPED_NOT_FOUND' | grep "11"
- [cmd] grep -qE "EXIT_PLAN_FOUND|EXIT_ALL_DONE|EXIT_SCOPED_NOT_FOUND" skills/mstack-run/scripts/lib.sh
- [cmd] grep -qE "exit (10|11|12|13|14)" skills/mstack-run/scripts/pick-next.sh
- [cmd] bash skills/mstack-run/scripts/pick-next.sh "999"; test $? -eq 11
- [cmd] bash -c 'PLANS_DIR=$(mktemp -d); echo -e "---\nid: 1\nstatus: done\n---" > "$PLANS_DIR/001-test.md"; bash skills/mstack-run/scripts/pick-next.sh; EXIT=$?; rm -rf "$PLANS_DIR"; test $EXIT -eq 10'
- [cmd] grep -qE "PICKER_EXIT|tmpfile|temp" skills/mstack-run/SKILL.md
