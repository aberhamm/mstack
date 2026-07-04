---
id: 031
title: Shared plan-reference resolver library (id <-> title <-> name)
status: done
blocked-by: []
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
completed: 2026-07-04
reviewed: false
qa: automated
---

## Requirements

Today mstack has no single place that maps a plan ID to its human title, or a
human name back to a plan ID. Every consumer re-derives it ad hoc:
`manifest.sh:resolve_plan_file()` finds the file for an ID, then callers run
`fm_get "$f" title` themselves (`status.sh:43`, `status.sh:294`,
`mstack-backlog/SKILL.md:54`). There is no reverse lookup at all — commands only
accept numeric IDs.

Both naming improvements the user asked for build on one shared resolver:

- **Display** (plan 032) needs `id -> "NNN: Title"` so no skill ever emits a
  bare ID the user has to look up.
- **Input** (plan 033) needs `name-or-id -> canonical id` so a plan can be
  referenced by title/slug, not just a number.

This plan adds that resolver to `lib.sh` as the single source of truth and
changes no caller behavior yet — it is pure foundation.

**Acceptance criteria:**

- [ ] `plan_file_for_id <id>` returns the repo-relative path of the plan whose
      frontmatter `id:` matches the normalized ID, scanning both the plans dir
      and `archive/`. Returns nonzero when no plan matches.
- [ ] `plan_title <id>` returns the frontmatter `title:` for that ID. When the
      title is empty/absent it falls back to a humanized filename slug, and to
      `(untitled)` only if even that is unavailable.
- [ ] `plan_label <id>` returns the display string `NNN: Title` (ID zero-padded
      to the filename convention width, min 3), e.g. `031: Shared plan-reference
      resolver library`. A missing title yields `NNN: <slug>`.
- [ ] `resolve_plan_ref <ref>` accepts either a numeric ID (bare or zero-padded)
      **or** a case-insensitive name fragment (matched against filename slug and
      frontmatter title) and prints the canonical **bare** numeric ID on stdout.
- [ ] `resolve_plan_ref` precedence is deterministic: exact numeric ID match
      first; then exact slug or title match; then a unique case-insensitive
      **whole-token** match (match on hyphen/space-delimited token boundaries, so
      `03` does NOT match `031/032/033` and `review` matches the word, not a
      substring of unrelated slugs). Multiple matches exit nonzero and print the
      candidate `NNN: Title` list to stderr (never silently pick one). No match
      exits with a distinct nonzero code.
- [ ] `resolve_plan_ref` is **archive-aware**: it reports whether the resolved
      plan is active or archived (a flag/mode or a status field in its output), so
      callers that need an *executable* plan (plan 033) can reject a name that
      matches only a done/archived plan with a clear message instead of silently
      resolving to a done ID.
- [ ] All functions live in `lib.sh`, are `bash 3.2`-compatible, and pass
      `shellcheck`. `bash -n` clean.
- [ ] Existing callers are unchanged in behavior (this plan may refactor
      `manifest.sh:resolve_plan_file` to delegate to `plan_file_for_id`, but its
      output contract must stay identical).

## Design

**Title source is settled:** frontmatter `title:` is the sole title source in
this repo — no plan uses an H1, and no filename-slug parsing exists today
(confirmed across `docs/plans/` and `docs/plans/archive/`). `plan_title` reads
`fm_get "$f" title` and only falls back to the slug when that is empty.

**ID normalization:** reuse the existing `normalize_id()` (strips leading zeros;
`008 -> 8`). IDs are stored unpadded in older plans (`id: 1`) and padded in
newer ones (`id: 030`); filenames are always zero-padded `NNN-slug.md`. Match on
the normalized bare ID; render with zero-padding to width 3 (the current
filename convention) so `plan_label 1` -> `001: ...`.

**Reverse resolution (`resolve_plan_ref`)** must be predictable, since it feeds
command parsing. Order:

1. If `ref` is all digits -> normalize -> confirm a plan with that ID exists ->
   return it.
2. Else lowercase `ref`; try exact match against each plan's slug (filename
   minus `NNN-` prefix and `.md`) and against the lowercased title.
3. Else collect plans whose slug or title contains `ref` **as a whole token**
   (delimited by `-`/space/start/end — not a raw substring). Exactly one -> that
   ID. Zero -> exit `no-match`. Two-plus -> exit `ambiguous`, printing each
   candidate via `plan_label` to stderr so the caller can surface them.

Return the match's active/archived status alongside the ID (e.g. a second output
field or a queryable flag) so plan 033 can reject archived-only matches for
execution scope.

Define two distinct nonzero exit codes (add to the `lib.sh` exit-code block,
e.g. `EXIT_REF_AMBIGUOUS`, `EXIT_REF_NOT_FOUND`) so callers can distinguish
"typo" from "be more specific".

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: add `plan_file_for_id`, `plan_title`,
  `plan_label`, `resolve_plan_ref`, and the two exit-code constants.
- `skills/mstack-run/scripts/manifest.sh`: optionally delegate
  `resolve_plan_file` to `plan_file_for_id` (dedupe), preserving output.
- A smoke check (extend an existing `bin/mstack-*-smoke` or add a small test
  harness under `skills/mstack-run/scripts/`) that exercises the four functions
  against this repo's own plans.

**Out of scope:** wiring these into any display path (032) or any command's
input parsing (033). Do not touch skill prose. Do not change how plans are
authored or numbered.

## Tasks

1. Add `EXIT_REF_AMBIGUOUS` / `EXIT_REF_NOT_FOUND` to the exit-code block in
   `lib.sh`.
2. Implement `plan_file_for_id`, `plan_title`, `plan_label` in `lib.sh`.
3. Implement `resolve_plan_ref` with the precedence above and candidate listing.
4. Refactor `manifest.sh:resolve_plan_file` to delegate (only if output is
   byte-identical; otherwise leave it and note the duplication).
5. Add a smoke test asserting: `plan_label` for a known archived ID contains the
   real title; `resolve_plan_ref` by slug fragment returns that ID; an ambiguous
   fragment exits `EXIT_REF_AMBIGUOUS`; an unknown fragment exits
   `EXIT_REF_NOT_FOUND`.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/manifest.sh`
- `[cmd]` `shellcheck skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/manifest.sh`
- `[assert]` sourcing `lib.sh` and running `plan_label 1` prints a string
  matching `^001: ` followed by the archived plan-1 title.
- `[assert]` `resolve_plan_ref` with a unique slug fragment of an existing plan
  prints that plan's bare ID.
- `[cmd]` `resolve_plan_ref` with a deliberately ambiguous fragment exits
  nonzero (assert exit code `EXIT_REF_AMBIGUOUS`).

## Implementation Notes

Added `normalize_id`, `plan_file_for_id`, `plan_title`, `plan_label`,
`resolve_plan_ref` (plus internal helpers `_ref_whole_token_match` /
`_plan_ref_status`) and two new exit codes (`EXIT_REF_AMBIGUOUS=21`,
`EXIT_REF_NOT_FOUND=22`) to `lib.sh`. Refactored `manifest.sh:resolve_plan_file`
to a one-line delegate to `plan_file_for_id` (verified byte-identical output
across active/archived/padded/unknown IDs). Added a standalone smoke harness
exercising all four acceptance-criteria assertions against this repo's real
plans (whole-token match confirmed: `03` resolves to plan 3, not 031/032/033).

**Deviation from Design:** `resolve_plan_ref` prints `"<bare_id> <status>"`
(two space-separated fields) rather than bare-ID-only with a global status
flag. The global-variable approach the Design suggested is silently broken
under the standard `id=$(resolve_plan_ref ...)` capture idiom — command
substitution forks a subshell and discards any global the function sets.
Encoding status in stdout is the robust alternative; callers wanting only the
ID take the first field (`${out%% *}`). This is the seam contract plan 033
consumes.

**Files changed:**

- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/manifest.sh` (modified)
- `skills/mstack-run/scripts/plan-ref-smoke.sh` (created)

**Commit:** `83c3201` — `feat(mstack-run): shared plan-reference resolver library`
