---
id: 023
title: Add goal-based scoping to mstack-run and manifest
status: done
blocked-by: [022]
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

The mstack-run orchestrator (SKILL.md) currently parses `$ARGUMENTS` for
numeric plan IDs to scope execution. It needs to also recognize goal names,
so users can write `/goal complete webhook-retry mstack plans` instead of
`/goal complete mstack plans 021, 022, 023, 024`.

The manifest needs a `goal` field for context but does NOT use composite keys —
it stores bare numeric IDs, same as today.

**Acceptance criteria:**

- [ ] SKILL.md Step 1b recognizes goal names in `$ARGUMENTS` (non-numeric tokens that aren't stop words)
- [ ] When a goal name is detected, mstack-run passes `--goal <slug>` to `pick-next.sh`
- [ ] When goal-scoped without explicit numeric IDs, mstack-run scans plan files to discover matching plan IDs and builds SCOPE_IDS from them
- [ ] The manifest stores a `goal` field at the root level (string, informational)
- [ ] The manifest continues to use bare numeric IDs in `scope_ids`, `terminal_ids`, and `picked_history` — no composite keys
- [ ] Progress output includes the goal name: `[mstack] Goal: webhook-retry`
- [ ] `/goal complete webhook-retry mstack plans` works end-to-end
- [ ] Mixed mode works: `/goal complete webhook-retry mstack plans 021, 022` passes `--goal` AND numeric IDs to the picker (AND composition)
- [ ] Backward compatible: numeric-only invocations work exactly as before
- [ ] When no goal is detected and no numeric IDs found, falls back to full backlog
- [ ] When argument parsing finds multiple candidate goal tokens, prints error and exits
- [ ] Anomaly handoff includes the goal name in context

## Design

**Argument parsing (Step 1b):** Process `$ARGUMENTS` in this order:
1. Expand range formats (e.g., `008-011` → `008,009,010,011`) — ranges
   contain dashes, so expand before stop-word filtering
2. Extract all numeric tokens → `SCOPE_IDS`
3. Remove stop words from remaining tokens
4. If exactly one non-stop-word non-numeric token remains → `GOAL_NAME`
5. If multiple remain → ambiguous, print error and exit

Stop words: `complete`, `mstack`, `plans`, `plan`, `are`, `done`, `failed`,
`or`, `the`, `all`, `pending`, `run`, `execute`, `finish`, `goal`.

Note: `/goal` itself is not in `$ARGUMENTS` (the `/goal` evaluator strips it).

**Goal discovery (when goal-scoped without explicit IDs):** Scan plan files for
matching `goal:` frontmatter. Collect their IDs into `SCOPE_IDS`:

```bash
for f in "$PLANS_DIR"/*.md; do
  plan_goal="$(fm_get "$f" goal)"
  if [ "$plan_goal" = "$GOAL_NAME" ]; then
    plan_id="$(fm_get "$f" id)"
    SCOPE_IDS="$SCOPE_IDS,$plan_id"
  fi
done
```

If zero plans match, print error and exit.

**Picker invocation (Step 2):** When `GOAL_NAME` is set, pass `--goal
$GOAL_NAME` to `pick-next.sh`. If `SCOPE_IDS` is also set, pass it as the
positional argument too (both filters, AND composition).

**Manifest changes:** `manifest.sh create` accepts an optional `--goal <slug>`
flag. Stored as a `"goal"` field at the root of the manifest JSON (string).
Does NOT change `scope_ids`, `terminal_ids`, or `picked_history` — these
remain bare numeric IDs. The goal field is informational, used in anomaly
handoff messages and status display.

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: update Step 1b argument parsing (add parsing order, stop-word list, goal discovery), Step 2 picker invocation, progress output, anomaly handoff context
- `skills/mstack-run/scripts/manifest.sh`: add `--goal` to `cmd_create`, store as root-level `goal` field

**Out of scope:** plan-multi (plan 024). pick-next.sh candidate filtering
(done in plans 021-022). Composite keys in manifest (explicitly avoided).

Testing approach: unit-only

## Tasks

1. Update SKILL.md Step 1b: document the 5-step argument parsing order (range expansion → numeric extraction → stop-word removal → goal detection → ambiguity check)
2. Update SKILL.md Step 1b: add goal discovery logic — when `GOAL_NAME` is set and `SCOPE_IDS` is empty, scan plan files for matching `goal:` field and build SCOPE_IDS
3. Update SKILL.md Step 2: pass `--goal $GOAL_NAME` to `pick-next.sh` when set, alongside numeric SCOPE_IDS if present
4. Update SKILL.md progress output: print `[mstack] Goal: <slug>` before the backlog summary when goal-scoped
5. Update `manifest.sh cmd_create`: parse `--goal <slug>` flag from arguments, store as `"goal"` field in manifest JSON root. No composite keys — scope_ids remain bare IDs.
6. Update SKILL.md anomaly handoff: include goal name in the handoff file's Goal section

## Verification

Checks:
- [cmd] grep -q "GOAL_NAME" skills/mstack-run/SKILL.md
- [cmd] grep -q "\-\-goal" skills/mstack-run/SKILL.md
- [cmd] grep -q '"goal"' skills/mstack-run/scripts/manifest.sh
- [cmd] bash -n skills/mstack-run/scripts/manifest.sh
- [assert] grep -c "stop.word\|GOAL_NAME\|goal.*slug" skills/mstack-run/SKILL.md | awk '{print ($1 >= 3) ? "PASS" : "FAIL"}' | grep PASS

## Implementation Notes

Added goal-based scoping to mstack-run. SKILL.md Step 1b now documents a 5-step argument parsing order (range expansion, numeric extraction, stop-word removal, goal detection, ambiguity check) with goal discovery logic that scans plan files for matching `goal:` frontmatter when no explicit IDs are given. Step 2 passes `--goal $GOAL_NAME` to pick-next.sh. Progress output prints `[mstack] Goal: <slug>` when goal-scoped. manifest.sh cmd_create accepts `--goal <slug>` flag and stores it as a root-level `"goal"` field (no composite keys). Anomaly handoff includes the goal name in the Goal section.

**Files changed:**

- `skills/mstack-run/SKILL.md` (modified)
- `skills/mstack-run/scripts/manifest.sh` (modified)

**Commit:** `56a4202` — `feat(mstack-run): goal-based scoping in orchestrator and manifest`
