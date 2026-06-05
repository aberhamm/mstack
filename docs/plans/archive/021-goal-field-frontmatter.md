---
id: 021
title: Add goal field to plan frontmatter and identity model
status: done
blocked-by: []
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

When two machines plan independently against the same repo, numeric plan IDs
collide (both sessions generate 001, 002, 003). The `goal:` field creates a
namespace so that plan identity becomes `(goal, id)` rather than just `id`.

This plan adds the field to the template and updates the picker's validation
and dependency resolution to be goal-aware.

**Acceptance criteria:**

- [ ] The plan template includes a `goal:` field in the frontmatter (optional, kebab-case slug)
- [ ] `pick-next.sh` duplicate ID detection (exit 14) scopes to within the same `goal:` value — two plans with `id: 1` are allowed if they have different `goal:` values
- [ ] Plans without a `goal:` field are treated as belonging to goal `""` (empty) — fully backward compatible
- [ ] `blocked-by` resolves within the same goal by default: plan 002 in `goal: auth` blocked by 001 resolves against `goal: auth`'s plan 001
- [ ] Cross-goal dependencies use `goal:id` syntax in `blocked-by` (e.g., `blocked-by: [auth:003]`)
- [ ] `DONE_IDS` tracking becomes goal-aware (keyed by `goal|id` pairs using pipe separator internally)
- [ ] Existing plans with bare numeric `blocked-by: [001]` and no `goal:` field continue to work (bare deps expand to `|001` matching empty-goal plans)
- [ ] Cycle detection works with goal-qualified identities (variable names use sanitized `goal_id` format)
- [ ] Exit code 15 (`EXIT_GOAL_NOT_FOUND`) is allocated in `lib.sh` for future use by plan 022

## Design

**Identity model:** A plan's identity is `(goal, id)`. When `goal:` is empty
or absent, identity is `("", id)` — backward compatible with all existing plans.

**Internal separator:** Use pipe `|` (not colon) as the internal separator for
goal-qualified keys in `DONE_IDS`, `ALL_ID_MAP`, and `NONDONE_IDS`. This avoids
collision with the colon already used in ALL_ID_MAP's `id:filepath` entries and
in the `blocked-by: [goal:id]` syntax. Internal format: `goal|id` (e.g.,
`auth|001`, `|001` for no-goal plans).

**ALL_ID_MAP separator change:** Currently uses `id:filepath`. Change to
`goal|id:filepath` so that `${_entry%%:*}` still extracts the identity part
(now `goal|id`) and `${_entry#*:}` still extracts the filepath. The duplicate
detection loop sorts on the identity part and compares consecutive entries.

**DONE_IDS format:** Change from `" 001 002 "` to `" |001 auth|002 "`. The
space-padded membership check `case "$DONE_IDS" in *" $dep "*)` works the same
way — the dep is just `goal|id` instead of bare `id`.

**blocked-by resolution:** When reading a plan's `blocked-by` list:
1. Read the current plan's `goal:` field via `fm_get`
2. For each dep in the blocked-by list:
   - If dep contains `:` → explicit cross-goal ref. Split on `:` to get
     `(dep_goal, dep_id)`, form `dep_goal|dep_id` for the DONE_IDS lookup
   - If dep is bare numeric → within-goal ref. Form `${current_goal}|${dep}`
     for the DONE_IDS lookup

**parse_blocked signature change:** Add a second parameter for the current
plan's goal. New signature: `parse_blocked_qualified "$blocked_raw" "$goal"`.
Returns space-separated `goal|id` tokens ready for DONE_IDS lookup. The old
`parse_blocked` is kept as-is for callers that don't need qualification.

**Cycle detection variable sanitization:** The `eval "DEPS_$_id"` pattern
requires valid bash variable names. Sanitize `goal|id` to `goal__id` (replace
`|` with `__`). Document this as intentional with an inline comment.

**Leading zero normalization:** Existing code strips leading zeros for scope
matching but not for DONE_IDS. This plan normalizes IDs in DONE_IDS entries
too: `auth|1` not `auth|001`. All lookups normalize before comparing.

**Files expected to change:**

- `skills/mstack-run/plan-template.md`: add `goal:` field to frontmatter
- `skills/mstack-run/scripts/pick-next.sh`: update ALL_ID_MAP, DONE_IDS, duplicate detection, blocked-by resolution, and cycle detection to use goal-qualified identity
- `skills/mstack-run/scripts/lib.sh`: add `EXIT_GOAL_NOT_FOUND=15` constant

**Out of scope:** Goal-based candidate filtering (plan 022). mstack-run
argument parsing (plan 023). plan-multi stamping (plan 024). Manifest changes
(plan 023).

Testing approach: unit-only

## Tasks

1. Add `goal:` field to `plan-template.md` frontmatter between `priority:` and `allows-migrations:`, with comment: `# optional; groups plans from the same planning session. Kebab-case slug.`
2. Add `EXIT_GOAL_NOT_FOUND=15` to `lib.sh` exit code constants.
3. Update `DONE_IDS` construction loop in `pick-next.sh`: read `goal:` via `fm_get` for each plan, normalize the id (strip leading zeros), store as `${goal}|${id_normalized}` in the space-padded set.
4. Update `ALL_ID_MAP` construction: build entries as `${goal}|${id_normalized}:${filepath}`. Update duplicate detection to compare the `goal|id` identity part (extracted via `${_entry%%:*}`).
5. Add `parse_blocked_qualified()` function: takes `(blocked_raw, current_goal)`, returns space-separated `goal|id` tokens. For each dep: if contains `:`, split as cross-goal ref; otherwise prefix with `${current_goal}|`. Normalize ids (strip leading zeros).
6. Update the candidate selection loop's blocked-by check: read the current plan's `goal:`, call `parse_blocked_qualified`, look up each qualified dep in DONE_IDS.
7. Update cycle detection: sanitize `goal|id` to `goal__id` for eval variable names (replace `|` with `__`). Add inline comment explaining the sanitization. Update `cycle_dfs` to use sanitized names for DEPS_ variables and qualified keys for DONE_IDS lookups.
8. Update the scoped-ID-not-found check (exit 11) to compare using normalized IDs, accounting for goal qualification.

## Verification

Checks:
- [cmd] grep -q "^goal:" skills/mstack-run/plan-template.md
- [cmd] grep -q "EXIT_GOAL_NOT_FOUND" skills/mstack-run/scripts/lib.sh
- [cmd] bash -n skills/mstack-run/scripts/pick-next.sh
- [cmd] bash -n skills/mstack-run/scripts/lib.sh
- [assert] grep -c "parse_blocked_qualified\|DONE_IDS.*goal\|goal|" skills/mstack-run/scripts/pick-next.sh | awk '{print ($1 >= 3) ? "PASS" : "FAIL"}' | grep PASS

## Implementation Notes

Added goal: field to plan-template.md frontmatter and EXIT_GOAL_NOT_FOUND=15 exit code to lib.sh. Updated pick-next.sh to use goal-qualified identity model throughout: DONE_IDS now stores "goal|id" tokens with pipe separator, ALL_ID_MAP uses "goal|id:filepath" entries, duplicate detection scopes to (goal, id) pairs, blocked-by resolution uses new parse_blocked_qualified() function supporting both within-goal and cross-goal (goal:id) references, and cycle detection sanitizes goal|id to goal__id for bash variable names. All existing plans without a goal: field are fully backward compatible (empty goal prefix "|").

**Files changed:**

- `skills/mstack-run/plan-template.md` (modified)
- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/pick-next.sh` (modified)

**Commit:** `4608031` — `feat(mstack-run): goal-qualified plan identity model`
