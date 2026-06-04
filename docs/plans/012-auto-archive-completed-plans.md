---
id: 012
title: Auto-archive completed plan files to docs/plans/archive/
status: done
blocked-by: []
priority:
allows-migrations: false
needs-review: none
completed: 2026-06-04
reviewed: false
qa: automated,verified
created: 2026-06-04
---

## Requirements

Completed plan files accumulate in `docs/plans/`, cluttering the directory
and reducing signal-to-noise for active work. After multiple plan-multi/run
cycles the directory fills with done plans that obscure pending ones.

Add automatic archival: when mstack-run marks a plan as `status: done`,
move the file to `docs/plans/archive/`. All existing tools must continue
working — done-ID resolution for blocked-by checks, status counts, plan
lookups, and ID sequencing must all account for archived plans.

**Acceptance criteria:**

- [ ] `docs/plans/archive/` is created during `init.sh bootstrap` if it doesn't exist
- [ ] `lib.sh` exposes an `archive_dir()` helper returning the archive path
- [ ] `pick-next.sh` scans both `$PLANS_DIR` and `$PLANS_DIR/archive/` when building DONE_IDS (blocked-by resolution still works after archival)
- [ ] `status.sh` dashboard counts archived plans in the "Done" total and shows recent completions from archive
- [ ] `status.sh plan <id>` can find and display a plan that has been archived
- [ ] `mstack-run/skill.md` Step 7a includes an archive step: after marking done and committing, `git mv` the plan file to `archive/` in the same or follow-up commit
- [ ] `mstack-run/skill.md` scoped dependency validation treats archived plans as done
- [ ] `mstack-plan-new/skill.md` scans `archive/` when finding the highest existing ID (prevents duplicate IDs)
- [ ] `mstack-plan-multi/skill.md` scans `archive/` when checking for existing plans and picking next ID
- [ ] `mstack-backlog/skill.md` accounts for archived done plans in its summary count
- [ ] All 11 existing done plans are migrated to `archive/` via `git mv`
- [ ] After migration, `status.sh dashboard` still shows correct done count and recent completions
- [ ] After migration, `pick-next.sh` with no pending plans exits cleanly (no errors)

## Design

The archive directory is flat (no date bucketing). It lives at
`docs/plans/archive/` and is committed to git (not gitignored).

**Files expected to change:**

- `scripts/lib.sh`: add `archive_dir()` helper that returns `$(plans_dir)/archive`
- `scripts/init.sh`: `mkdir -p` the archive dir during bootstrap
- `scripts/pick-next.sh`: add a second `find` pass over `$PLANS_DIR/archive/` when building DONE_IDS and NONDONE lists (3 find calls need updating)
- `scripts/status.sh`: extend `cmd_dashboard` to scan archive/ for done counts and recent completions; extend `cmd_plan` to fall back to archive/ when plan not found in main dir
- `mstack-run/skill.md`: add archive step after Step 7a commit; update scoped dependency validation text
- `mstack-plan-new/skill.md`: update ID-scanning instruction to include `archive/*.md`
- `mstack-plan-multi/skill.md`: update existing-plan check and ID picking to include archive/
- `mstack-backlog/skill.md`: update done-count summary to include archived plans
- `docs/plans/archive/`: new directory, receives migrated done plans

**Testing approach:** unit-only

**Out of scope:**
- Date-bucketed archive directories (YAGNI)
- JSON index or manifest files
- Archive browsing/search commands
- Automatic cleanup or deletion of archived plans

## Tasks

1. Add `archive_dir()` helper to `scripts/lib.sh` (returns `$(plans_dir)/archive`) and add `mkdir -p "$(archive_dir)"` to `scripts/init.sh` bootstrap flow
2. Update `scripts/pick-next.sh`: all three `find` calls that build DONE_IDS and scan for plans must also include files from `$PLANS_DIR/archive/` — append a second find or use brace expansion; keep `-maxdepth 1` on both paths
3. Update `scripts/status.sh`: `cmd_dashboard` scans archive/ for done counts and recent completions; `cmd_plan` falls back to `$pdir/archive/` when a plan ID isn't found in the main directory
4. Update `mstack-run/skill.md` Step 7a: after the commit that marks the plan done, add a `git mv "$PLAN_FILE" "$PLANS_DIR/archive/"` and commit with message `chore: archive plan <id> (done)`. Update scoped dependency validation to note that archived plans count as done.
5. Update `mstack-plan-new/skill.md` (Step 2 ID scanning), `mstack-plan-multi/skill.md` (Step 5 ID picking and Step 2 existing-plan check), and `mstack-backlog/skill.md` (done summary) to include `archive/*.md` in their scans
6. Migrate all 11 existing done plans: `git mv docs/plans/0*.md docs/plans/archive/` for each done plan. Run `status.sh dashboard`, `pick-next.sh`, and `status.sh plan 011` to verify everything works post-migration.

## Verification

Checks:
- [cmd] bash scripts/status.sh dashboard 2>&1 | grep -q "Done:.*plans"
- [cmd] bash scripts/pick-next.sh 2>&1; test $? -eq 0
- [cmd] bash scripts/status.sh plan 011 2>&1 | grep -q "PLAN 011"
- [cmd] test -d docs/plans/archive
- [cmd] ls docs/plans/archive/*.md | wc -l | grep -q "11"
- [cmd] ls docs/plans/*.md 2>/dev/null | grep -v archive | wc -l | tr -d ' ' | grep -q "^[01]$"
