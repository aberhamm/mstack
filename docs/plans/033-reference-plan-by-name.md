---
id: 033
title: Reference plans by name/title, not just numeric ID
status: in-progress
blocked-by: [031]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
---

## Requirements

Commands that take a plan identifier only accept numeric IDs today
(`/mstack-run 008,009`, `/mstack-plan-doctor 042`, `/mstack-status 042`). The
user wants to reference a plan by its name/title too, so they don't have to look
the number up. Numeric IDs must keep working unchanged; names are an additive
alternative resolved through the plan-031 resolver.

**Acceptance criteria:**

- [ ] `pick-next.sh`'s scope filter accepts name tokens: each scope token is run
      through `resolve_plan_ref` to a canonical ID before the membership set is
      built. Pure-numeric scopes behave exactly as before.
- [ ] `mstack-run` Step 1b resolves names **only from explicitly-delimited name
      forms** (a quoted string or a `name:`/`plan:`-prefixed token), NOT from any
      leftover prose word. A bare incidental word that happens to whole-token
      match a plan must NOT silently scope the run to it — "finish the resolver
      plan" must not auto-scope to 031. Unrecognized leftover prose falls back to
      the full backlog with a printed note, or aborts; it never guesses a scope.
- [ ] Names are resolved only from non-numeric tokens (numeric tokens are already
      extracted as `SCOPE_IDS` in Step 2 before name resolution), so a numeric
      like `042` never routes through the name matcher.
- [ ] A name that matches **only an archived/done plan** is rejected for
      execution scope with "matches only a completed plan: NNN: Title" (using the
      archive-aware resolver from 031), not silently resolved to a done ID that
      then trips `pick-next`'s "all scoped plans done".
- [ ] An ambiguous name aborts with a message that distinguishes "this looked
      like a name and was ambiguous (candidates: ...)" from a hard error, and
      points to the numeric form as the unambiguous path.
- [ ] `mstack-plan-doctor` scoped runs accept a name or filename in addition to
      an ID.
- [ ] `mstack-status <ref>` accepts a name.
- [ ] `argument-hint` strings for these skills read `<plan-id|name>` (or similar)
      so the capability is discoverable.
- [ ] Ambiguous matches fail closed with the candidate `ID: Title` list; the
      command does not run against a guessed plan.

## Design

All resolution goes through `resolve_plan_ref` (plan 031) — one matcher, one
precedence, one ambiguity behavior. Numeric IDs short-circuit first, so existing
scoped runs are untouched.

**Free-form argument rule (hard, not guidance):** `mstack-run` accepts prose like
"complete mstack plans 008, 009". A leftover prose word that incidentally
whole-token matches a plan must never silently become the scope — that is a
guess, and the eng review flagged it as the exact failure ("finish the resolver
plan" → silently runs only 031). So names in `mstack-run` scope position must be
**explicitly delimited**: a quoted string (`"plan-ref resolver"`) or a
`name:`/`plan:` prefix. Anything else non-numeric after stop-word removal is
treated as prose: fall back to the full backlog with a printed note (or abort),
never auto-scope. `mstack-plan-doctor`/`mstack-status` take a single identifier
argument, so a bare slug there is unambiguous and needs no delimiter. Full fuzzy
multi-word title parsing in free prose is out of scope.

**Files expected to change:**

- `skills/mstack-run/scripts/pick-next.sh`: resolve scope tokens via
  `resolve_plan_ref`; keep numeric fast-path; surface ambiguity via the existing
  nonzero-exit + stderr pattern.
- `skills/mstack-run/SKILL.md`: Step 1b spec — add the name-resolution step and
  the ambiguity/abort rule; update the description's accepted-formats list.
- `skills/mstack-plan-doctor/SKILL.md`: accept name in scoped runs; update
  `argument-hint`.
- `skills/mstack-status/SKILL.md` + `status.sh` `plan` dispatch: accept name.
- `skills/mstack-plan-new/SKILL.md` (optional): `-- depends-on` may accept names
  (resolve to IDs at scaffold time). Include only if low-risk.

**Out of scope:** typo/edit-distance correction, matching against archived plans
for *execution* scope (a name that only matches a done plan should say so, not
silently no-op), and any change to how plans are numbered.

## Tasks

1. Add a name-resolution pre-pass to `pick-next.sh` scope handling.
2. Update `mstack-run` Step 1b to resolve names and abort-on-ambiguous.
3. Update `mstack-plan-doctor` and `mstack-status` to accept names; fix
   `argument-hint`s.
4. Update the accepted-formats prose in the `mstack-run` description.
5. (Optional) name-aware `-- depends-on` in `mstack-plan-new`.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/pick-next.sh`
- `[cmd]` `shellcheck skills/mstack-run/scripts/pick-next.sh`
- `[assert]` `pick-next.sh` given a unique slug fragment of a pending plan
  selects that plan (same result as passing its numeric ID).
- `[cmd]` `pick-next.sh` given an ambiguous name exits nonzero (assert the
  ambiguity exit code) and lists candidates on stderr.
- `[cmd]` `pick-next.sh` given a purely numeric scope still behaves identically
  (regression: same selected file as before this change).
