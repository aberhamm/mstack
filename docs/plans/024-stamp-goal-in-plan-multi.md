---
id: 024
title: Stamp goal field in plan-multi
status: done
blocked-by: [021]
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

When plan-multi creates plans from a high-level goal, it should automatically
stamp every plan with a `goal:` frontmatter field derived from the goal
description. This connects plan creation to goal-scoped execution — the user
plans once, and the suggested `/goal` command uses the goal name instead of
numeric ID ranges.

This plan is independent of the picker/mstack-run changes (plans 022-023) and
only depends on the template having the field (plan 021).

**Acceptance criteria:**

- [ ] plan-multi derives a kebab-case slug from the user's goal description (e.g., "Add Stripe webhook retry logic" -> `stripe-webhook-retry`)
- [ ] The slug is max 40 characters, lowercase, ASCII alphanumeric + hyphens only
- [ ] Non-ASCII characters are stripped (no Unicode in slugs)
- [ ] Every plan file created by plan-multi includes `goal: <slug>` in its frontmatter
- [ ] The Step 6 summary suggests a goal-based `/goal` command (e.g., `/goal complete stripe-webhook-retry mstack plans`) as the primary command
- [ ] The Step 6 summary still lists numeric IDs for reference
- [ ] If the user provides a custom goal slug (e.g., "plan this, goal: wh-retry"), use it verbatim
- [ ] plan-new (single plan scaffold) does NOT auto-stamp a goal

**Slug derivation rules:**

- [ ] Lowercase the goal, strip non-alphanumeric/non-space characters
- [ ] Split into words, filter stop words one word at a time (not phrases)
- [ ] Stop words: a, an, the, to, for, from, in, on, with, by, and, or, but, add, create, build, implement, make, set, up, update, fix, refactor, enable, disable, migrate, support
- [ ] Take first 4-6 meaningful words, join with hyphens
- [ ] Truncate after the last complete hyphen-separated token that fits within 40 chars
- [ ] If result is empty after filtering, fall back to first 3 words of the original (lowercased, joined with hyphens)

## Design

**Slug derivation** happens at Step 5 (write plan files), before writing any
files. The slug is derived once and stamped into all plans in the batch.

Algorithm:
1. Check for custom slug: if goal contains `goal:` or `slug:` followed by
   non-whitespace, extract everything from the token after the colon to the
   next whitespace (or end). Use as slug verbatim (already kebab-case).
2. If no custom slug: lowercase, strip non-alphanumeric/non-space chars
3. Split into words
4. Filter stop words (single-word matching only — "set" and "up" are separate entries)
5. Take first 4-6 meaningful words
6. Join with hyphens
7. Truncate after the last hyphen-separated token that fits within 40 chars

**Note on Step 6 coordination:** Plan 023 teaches mstack-run to parse goal
names from `/goal` commands. This plan changes the suggested command format
in plan-multi's Step 6 output. Both plans are independently correct — plan-multi
can suggest the goal-based command even before mstack-run can parse it (the user
just uses numeric IDs in the meantime). Once both land, the full flow works.

**Files expected to change:**

- `skills/mstack-plan-multi/SKILL.md`: add slug derivation in Step 5, stamp `goal:` in frontmatter, update Step 6 summary format

**Out of scope:** Changing mstack-run, pick-next.sh, manifest.sh (plans
022-023). Changing plan-new — single plans don't need goal grouping.

Testing approach: unit-only

## Tasks

1. Add slug derivation logic to plan-multi SKILL.md Step 5: custom slug detection first, then auto-derivation (lowercase, strip, split, filter, take, join, truncate)
2. Update Step 5 plan file writing: include `goal: <slug>` in the frontmatter of every generated plan, after `priority:` and before `allows-migrations:`
3. Update Step 6 summary: primary suggested command uses goal name (`/goal complete <slug> mstack plans`), with numeric ID list shown as reference below
4. Add the stop-word list as a clearly delineated block in the slug derivation instructions so it's easy to find and extend

## Verification

Checks:
- [cmd] grep -q "goal:" skills/mstack-plan-multi/SKILL.md
- [assert] grep -c "kebab\|slug\|stop.word" skills/mstack-plan-multi/SKILL.md | awk '{print ($1 >= 3) ? "PASS" : "FAIL"}' | grep PASS
- [cmd] grep -q "complete.*mstack\|goal.*command" skills/mstack-plan-multi/SKILL.md

## Implementation Notes

Added slug derivation logic to plan-multi SKILL.md Step 5 with custom slug detection (goal:/slug: tokens) and auto-derivation algorithm (lowercase, strip, split, filter stop words, take 4-6 words, join, truncate to 40 chars). Stop-word list placed in a clearly delineated block for easy extension. Frontmatter instructions updated to include `goal: <slug>` after `priority:`. Step 6 summary now shows the goal-based `/goal complete <slug> mstack plans` as the primary suggested command with numeric IDs as reference.

**Files changed:**

- `skills/mstack-plan-multi/SKILL.md` (modified)

**Commit:** `32d65e5` — `feat(mstack-plan-multi): stamp goal field and suggest goal-based commands`
