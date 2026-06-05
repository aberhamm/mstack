---
id: 017
title: Persisted execution manifest
status: pending
blocked-by: [016]
allows-migrations: false
needs-review: none
created: 2026-06-05
---

## Requirements

When a scoped /goal runs, there is no persistent record of which plans were
requested, which have been picked, or how many iterations have occurred. This
means mid-execution mutations (renames, moves, ID changes) go undetected and
the agent can't distinguish "stuck" from "making progress."

Add a persisted execution manifest that tracks scoped goal state across
iterations.

**Acceptance criteria:**

- [ ] `.mstack/execution-manifest.json` is written at the start of a scoped goal run
- [ ] Manifest contains: scope_ids (normalized), resolved file paths per ID, picked_history (list), terminal_ids (set of done/failed IDs), iteration_count, created_at, updated_at
- [ ] Each iteration: manifest is read, iteration_count incremented, picked plan appended to picked_history, terminal IDs updated from current plan statuses
- [ ] Each iteration: file paths are re-resolved from disk and compared to manifest; path divergence (rename/move) is logged to stderr as a warning
- [ ] Manifest is deleted on clean goal completion (all scoped IDs terminal)
- [ ] Stale manifests (from crashed sessions) are detected at startup and logged
- [ ] New script `manifest.sh` handles read/write/delete/validate operations
- [ ] SKILL.md Step 1 wired to create manifest at goal start; Step 2 wired to update after each pick

## Design

**Manifest schema:**

```json
{
  "version": 1,
  "scope_ids": ["016", "017", "018"],
  "plans": {
    "016": { "file": "docs/plans/016-foo.md" },
    "017": { "file": "docs/plans/017-bar.md" },
    "018": { "file": "docs/plans/018-baz.md" }
  },
  "picked_history": ["016", "017"],
  "terminal_ids": ["016"],
  "prev_terminal_count": 0,
  "path_diverged": [],
  "iteration_count": 2,
  "created_at": "2026-06-05T10:00:00Z",
  "updated_at": "2026-06-05T10:15:00Z"
}
```

**Path staleness handling:** Each iteration, re-resolve each scope ID to its
current file path on disk (scan plans/ and archive/). If the resolved path
differs from the manifest's stored path, update the manifest and emit a
warning to stderr: `"plan 016 moved: docs/plans/016-foo.md -> docs/plans/016-bar.md"`.
This is informational, not a hard failure — plan 018 uses the divergence signal
for anomaly classification.

**Stale manifest detection:** At startup, if a manifest already exists, check
its `updated_at`. If older than 1 hour, log a warning: `"stale manifest from
previous session detected, overwriting"`. Always overwrite with fresh state
for the current goal run.

**SKILL.md wiring (owned by this plan):**
- Step 1 (startup): after scope parsing in Step 1b, call `manifest.sh create` with scope IDs
- Step 2 (after pick): call `manifest.sh update` with picked ID and current terminal IDs (derived by scanning frontmatter `status:` of all scoped plan files for done/failed)
- Step 7a (success path only): call `manifest.sh delete` after the archive/commit step. Do NOT delete on failure — anomaly handler (plan 019) needs the manifest for debugging

**manifest.sh must source lib.sh** for shared helpers: `fm_get`, `iso_now`, `ensure_mstack_dir`, `plans_dir`, `archive_dir`, `has_jq`.

**Files expected to change:**

- `skills/mstack-run/scripts/manifest.sh` (NEW): create/read/update/delete/validate commands
- `skills/mstack-run/scripts/lib.sh`: add manifest path constant
- `skills/mstack-run/SKILL.md`: wire manifest calls into Steps 1, 2, and 7

**Out of scope:** Anomaly detection logic (plan 018), auto-handoff (plan 019).
The manifest is a data layer; consumers come later.

Testing approach: unit-only

## Tasks

1. Add MANIFEST_FILE constant to lib.sh pointing to `.mstack/execution-manifest.json`
2. Create manifest.sh with subcommands: `create <scope_ids_csv>`, `read`, `update <picked_id> <terminal_ids_csv>`, `delete`, `validate`
3. `create` subcommand: resolve each scope ID to a file path, write initial manifest JSON with iteration_count=0
4. `update` subcommand: read manifest, increment iteration_count, append to picked_history, update terminal_ids, store prev_terminal_count (previous len of terminal_ids before this update), re-resolve file paths and log divergences (append changed IDs to path_diverged array), write back
5. `validate` subcommand: check manifest exists and is valid JSON, report stale manifests (updated_at older than 1 hour)
6. Wire SKILL.md Step 1b: after scope validation, run `manifest.sh create "$SCOPE_IDS"`
7. Wire SKILL.md Step 2: after picker returns and plan executes, derive TERMINAL_IDS by scanning scoped plan frontmatter for status: done or failed, then run `manifest.sh update "$PLAN_ID" "$TERMINAL_IDS"`
8. Wire SKILL.md Step 7a (success path): run `manifest.sh delete` after the archive/commit step

## Verification

Checks:
- [cmd] test -f skills/mstack-run/scripts/manifest.sh
- [assert] grep -c "create\|read\|update\|delete\|validate" skills/mstack-run/scripts/manifest.sh | awk '{print ($1 >= 5) ? "PASS" : "FAIL"}' | grep PASS
- [cmd] grep -q "MANIFEST_FILE\|execution-manifest" skills/mstack-run/scripts/lib.sh
- [cmd] grep -q "manifest.sh" skills/mstack-run/SKILL.md
