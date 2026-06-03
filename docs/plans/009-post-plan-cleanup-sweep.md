---
id: 9
title: Add post-plan cleanup sweep to mstack-run and mstack-handoff
status: done
completed: 2026-06-03
reviewed: false
qa: automated,verified
blocked-by: [8]
needs-review: none
created: 2026-06-02
---

## Requirements

After implementing a plan, the worker commits and moves on. But implementation
often leaves artifacts: files that were created during experimentation but never
imported, functions that were scaffolded but never called, unused imports added
during development, or temporary debug code. The dead code health category
catches some of this at the score level, but it operates on the entire codebase,
not on the specific changes from this plan. A targeted cleanup pass on just the
files touched by the current plan would catch artifacts early, before they
accumulate across multiple plans.

Similarly, mstack-handoff captures the session state for a clean restart, but
doesn't check whether the current working tree has leftover artifacts from the
work being handed off.

**Acceptance criteria:**

- [ ] After the health gate passes and before code review (between Step 5 and Step 6 in mstack-run), a cleanup sweep runs on only the files created or modified by the current plan
- [ ] The sweep checks for: unused imports/requires, functions/classes defined but never called within the changed files, files created but not imported by any other file, TODO/FIXME/HACK comments added during implementation, console.log/print/debug statements added during implementation
- [ ] If cleanup issues are found, the worker fixes them and re-runs the health gate to confirm no regressions
- [ ] If no cleanup issues are found, the worker proceeds directly to code review
- [ ] The cleanup sweep output uses the same `[mstack]` prefix as progress output (plan 008): `[mstack] ├─ Cleanup: removed 2 unused imports, 1 debug statement`
- [ ] mstack-handoff includes a pre-handoff check: scan for uncommitted files in the working tree that look like artifacts (files matching patterns like `*.tmp`, `*.bak`, `test-*`, `debug-*`, or files in the repo root that don't match the project's typical structure)
- [ ] The handoff pre-check reports artifacts found but does not delete them (the user decides)
- [ ] The cleanup sweep is scoped to the plan's changes only, never touches files outside the current plan's diff

## Design

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: add cleanup sweep step between health gate and code review
- `skills/mstack-handoff/SKILL.md`: add pre-handoff artifact check

**Approach:**

**mstack-run cleanup (new Step 5c, after verification gate, before code review):**

The worker already knows which files it changed (from the implementation step).
After the health gate passes:

1. Get the list of files changed by this plan: `git diff --name-only HEAD~1`
2. For each changed file, check for:
   - Unused imports: scan import/require statements, check if the imported name
     appears elsewhere in the file
   - Dead functions: functions/classes defined in the file that are not called
     anywhere in the file or imported by other files in the diff
   - Debug artifacts: `console.log`, `print()` (in non-print-oriented code),
     `debugger`, `TODO`, `FIXME`, `HACK` comments
   - Orphan files: new files (in the diff) that are not imported/referenced by
     any other file in the project
3. If issues found: fix them in the working tree (nothing is committed yet at this stage), re-run health gate to confirm no regressions
4. If no issues: proceed to code review
5. Output: `[mstack] ├─ Cleanup: <summary>` or `[mstack] ├─ Cleanup: nothing to clean`

The sweep is intentionally lightweight. It catches the obvious artifacts that
slip through during implementation. It is not a full dead code analysis (that's
what the health gate's dead code category does for the whole codebase).

**mstack-handoff artifact check (new section before output):**

Before generating the handoff summary:

1. Check `git status` for untracked files
2. Filter for likely artifacts: `*.tmp`, `*.bak`, `*.orig`, `test-*`, `debug-*`,
   `*.log`, files in repo root that weren't there at the start of the session
3. Check `git stash list` for stashed changes
4. Report in the handoff output:
   ```
   Cleanup check:
     2 untracked files may be artifacts:
       debug-webhook.ts (created during plan 002 debugging)
       test-output.json (test fixture, possibly temporary)
     1 git stash entry
   ```
5. If nothing found: `Cleanup check: working tree is clean`

**Out of scope:**

- Modifying the dead code health category (it stays as a whole-codebase check)
- Auto-deleting files in the handoff check (report only)
- Cleanup of files outside the current plan's diff in mstack-run
- Language-specific AST analysis (the sweep uses grep-level heuristics)

## Tasks

1. Add "Step 5b: Cleanup sweep" section to mstack-run SKILL.md after the health gate step, with the file-scoped checks described above
2. Add the cleanup output format using the `[mstack]` prefix
3. Add the amend-and-recheck flow for when cleanup issues are found
4. Add "Pre-handoff artifact check" section to mstack-handoff SKILL.md before the output generation step
5. Add the artifact detection patterns and reporting format to mstack-handoff

## Verification

- [assert] grep -i 'cleanup sweep\|cleanup.*step\|Step 5b' skills/mstack-run/SKILL.md
- [assert] grep 'git diff --name-only\|files changed\|changed files' skills/mstack-run/SKILL.md
- [assert] grep -i 'unused import\|dead function\|debug.*artifact\|console.log\|orphan' skills/mstack-run/SKILL.md
- [assert] grep -i 'artifact\|cleanup\|untracked' skills/mstack-handoff/SKILL.md
- [assert] grep -i '\.tmp\|\.bak\|\.orig\|debug-' skills/mstack-handoff/SKILL.md
