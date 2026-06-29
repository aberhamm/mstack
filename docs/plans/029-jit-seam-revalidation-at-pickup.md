---
id: 029
title: JIT seam re-validation at plan pickup in mstack-run
status: in-progress
blocked-by: [028]
priority:
goal: doctor-autonomy-hardening
allows-migrations: false
needs-review: none
created: 2026-06-26
---

## Requirements

Plans are validated big-bang upfront, when downstream plans reference upstream
artifacts that do not exist yet — so their seam assumptions cannot be checked
against reality. By the time `mstack-run` PICKS a plan, its `blocked-by`
ancestors are `done` and their artifacts are REAL, but Step 3b only does a
static placeholder check. A plan whose seam assumption diverged from what the
upstream plan actually built gets implemented on a false premise, and the worker
discovers it mid-implementation (or worse, ships drift).

Extend Step 3b to re-validate a picked plan's upstream seam assumptions against
the now-real codebase before implementation.

**Acceptance criteria:**

- [ ] When a picked plan has `blocked-by` deps that are now `done`, Step 3b
      parses the plan's `<!-- mstack:seam ... -->` block (the machine-readable
      contract plan 028 emits — NOT freeform prose) and checks each `assumed:`
      entry against the actual codebase. `seam-check.sh` reads the structured
      block with `awk`/`grep` per the grammar fixed in `seam-contracts.md`; if a
      plan has no seam block, it is treated as having no verifiable assumptions
      (exit 0, backward compatible).
- [ ] Verification per assumed entry follows the IDENTICAL rule pinned in
      `seam-contracts.md` (plan 028): an entry is VERIFIABLE iff it has a `file:`.
      Then assert the file exists (`test -f`) and, if `shape:` is present, that
      the shape token appears WITHIN that file (`grep -q`). MISSING (file absent)
      and a verifiable SHAPE mismatch (the `shape:` token absent from that file)
      are STALE → block. An entry with NO `file:` is UNVERIFIABLE → never blocks
      (a bare `name:` is never grepped repo-wide).
- [ ] A confirmed stale seam blocks the plan, mirroring the existing
      incomplete-spec path EXACTLY: set `status: blocked` AND add
      `needs-review: eng`, commit only the plan file, print a clear diagnostic
      naming the plan, the assumed artifact, and what was found, and direct the
      user to `/mstack-plan-doctor NNN`.
- [ ] The check is lightweight and bounded — targeted existence/grep checks of
      the structured block, NOT a full doctor run — and adds NO dependency on an
      external model (pickup stays deterministic and fast).
- [ ] "Verifiable" is defined crisply and identically to plan 028: an assumed
      entry is verifiable iff it carries a `file:` path (checked for existence,
      and for the in-file `shape:` token if present). Everything else is
      UNVERIFIABLE and does not block. Only verifiable mismatches block — no
      false blocks on prose-only or name-only contracts.
- [ ] Backward compatible: plans with no `blocked-by`, no seam block, or only
      UNVERIFIABLE entries flow through Step 3b exactly as today (exit 0).

## Design

This is the execution-side complement to plan 028's authoring-side check: 028
defines the PRODUCED/ASSUMED contract AND emits the machine-readable
`<!-- mstack:seam ... -->` block into each plan; 029 PARSES that block (never the
prose) and evaluates the `assumed:` side against real code at pickup. The
prose-vs-shell mismatch that would otherwise sink this pair is resolved by 028
emitting a deterministic, shell-parseable block — `seam-check.sh` consumes the
block grammar fixed in `seam-contracts.md`, so it never has to interpret freeform
prose. Shape checking at pickup is a string-presence heuristic (is the declared
`shape:` token present within the entry's `file:`?), not AST parsing; entries
without a `file:` are UNVERIFIABLE and do not block (verifiability is anchored on
`file:`, identically to plan 028 — a bare `name:`/`shape:` is never grepped
repo-wide).

`seam-check.sh` has its OWN exit-code contract (it is a standalone script
consumed directly by Step 3b, distinct from `pick-next.sh`'s documented 10–19
picker range in `lib.sh`): `0` = clean OR no verifiable assumptions, `20` =
confirmed stale seam. `20` sits outside the picker range so there is no collision;
Step 3b interprets `20` specifically.

**Files expected to change:**

- `skills/mstack-run/SKILL.md`: extend "Step 3b: Plan readiness gate" with a
  "JIT seam re-validation" sub-step that runs when `blocked-by` deps are done;
  on a confirmed stale seam, block the plan and route to Step 8 (schedule next
  iteration) exactly as the existing readiness-failure path does — do NOT
  implement another plan in the same invocation (one invocation does exactly one
  plan; `/goal` handles continuation).
- `skills/mstack-run/scripts/seam-check.sh` (new): given a plan file, parse its
  `mstack:seam` block and assert each `assumed:` entry's existence/shape against
  the repo; exit `20` + one-line stderr diagnostic on a confirmed mismatch, exit
  `0` when clean, when there is no seam block, or when all entries are
  UNVERIFIABLE. Follows repo script style (`#!/usr/bin/env bash`,
  `set -euo pipefail`).
- `skills/mstack-plan-doctor/references/seam-contracts.md` (read-only): the
  shared contract grammar + definition authored in plan 028.

**Out of scope:** re-running the full doctor at pickup (too heavy); the
authoring-side check and block emission (plan 028); any cross-model audit at
pickup (keep pickup deterministic and fast).

## Tasks

1. Add `scripts/seam-check.sh`: parse the picked plan's `mstack:seam` block with
   `awk`/`grep` per the grammar in `seam-contracts.md`; for each VERIFIABLE
   `assumed:` entry (one with a `file:`) assert the file exists (`test -f`) and,
   if `shape:` is present, that the shape token appears WITHIN that file
   (`grep -q`); skip entries with no `file:` (UNVERIFIABLE); exit `0` if all
   verifiable entries resolve, if there is no seam block, or if all entries are
   UNVERIFIABLE; exit `20` with a one-line stderr diagnostic on a confirmed
   verifiable mismatch.
2. Extend Step 3b: after the placeholder check, if the plan's `blocked-by` deps
   are done, run `seam-check.sh` on the plan.
3. On exit `20`, block the plan using the same mechanics as the existing
   incomplete-spec path: set `status: blocked` + add `needs-review: eng`, commit
   only the plan file, print "plan NNN: stale seam — <assumed> not found /
   differs; run /mstack-plan-doctor NNN", then route to Step 8 (schedule next
   iteration) — do not implement another plan this invocation. While here,
   harmonize the existing Step 3b incomplete-spec wording ("skip to the next
   plan in the backlog", SKILL.md ~:454) to the same "return the Step 8 signal;
   `/goal` drives the next iteration" phrasing, so both block paths describe the
   one-plan-per-invocation rule identically.
4. On exit `0`, proceed to implementation unchanged.
5. Add `bash -n` + `shellcheck` for the new script to the dev-check flow; keep
   no-dep / no-seam-block / UNVERIFIABLE-only plans flowing through unchanged.

## Verification

Checks:
- [cmd] test -f skills/mstack-run/scripts/seam-check.sh
- [cmd] bash -n skills/mstack-run/scripts/seam-check.sh
- [cmd] shellcheck skills/mstack-run/scripts/seam-check.sh
- [cmd] grep -qiE "seam" skills/mstack-run/SKILL.md
- [cmd] grep -qiE "needs-review: eng" skills/mstack-run/SKILL.md
- [cmd] grep -qiE "Step 8" skills/mstack-run/SKILL.md
- [cmd] bash -c 'D=$(mktemp -d); printf -- "---\nid: 1\nstatus: pending\nblocked-by: []\n---\n" > "$D/001-x.md"; bash skills/mstack-run/scripts/seam-check.sh "$D/001-x.md"; E=$?; rm -rf "$D"; test $E -eq 0'
- [cmd] bash -c 'D=$(mktemp -d); printf -- "---\nid: 2\nstatus: pending\nblocked-by: [1]\n---\nno seam block here\n" > "$D/002-x.md"; bash skills/mstack-run/scripts/seam-check.sh "$D/002-x.md"; E=$?; rm -rf "$D"; test $E -eq 0'
- [manual] craft a plan with an `mstack:seam` assumed entry whose `file:` is missing (or whose `shape:` token is absent); confirm seam-check.sh exits 20 with a one-line diagnostic
- [manual] construct A (produces a real symbol in a real file, marked done) + B (assumes a differently-named symbol from A); confirm pickup of B blocks with a stale-seam diagnostic, sets needs-review: eng, and routes to the next iteration
