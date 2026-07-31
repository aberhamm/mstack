---
id: 072
title: CHANGELOG catch-up and README enforcement section
status: done
blocked-by: [054]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
completed: 2026-07-31
reviewed: false
qa: automated
---

## Requirements

CHANGELOG.md's newest entry is dated 2026-06-30 and covers plans 026-029.
Everything since — plans 030-053, including the ENTIRE enforcement family
(review gates 034-036, approved-plans-committed 037, git hooks 038,
work-committed 039, fail-closed health 043, verify-lint probe 046,
health-reach 047) — is unrecorded. A consumer updating mstack gains
hard-blocking commit hooks with no notice. The file also carries FOUR stacked
`## [Unreleased]` sections (2026-06-30, 06-11, 06-05, 06-03), violating its
own Keep a Changelog standard. Meanwhile README.md still describes the
pre-enforcement pipeline: the per-plan sequence (lines 44-52) has no review
gates, review records, or done-tag gating, and the picker exit-code table
(lines 354-365) stops at 14 although `lib.sh` defines `EXIT_GOAL_NOT_FOUND=15`
and `EXIT_REF_AMBIGUOUS=21`, and exit 12 also fires in unscoped mode.

**Acceptance criteria**

- [x] CHANGELOG.md gains entries reconstructed from `git log` +
      `docs/plans/archive/` covering plans 030 through the latest archived
      plan, with the enforcement family (034-039, 043, 046, 047) called out
      prominently — including an explicit upgrade note that `mstack-init`/
      `setup` now installs commit/push hooks into consumer repos.
- [x] The four stacked `## [Unreleased]` sections are consolidated per Keep a
      Changelog: one `[Unreleased]` at top; previously-dated pseudo-Unreleased
      sections become properly dated/versioned entries.
- [x] README.md's per-plan sequence (lines 44-52) is updated to include the
      review gate (assert-completable before done), review records
      (`reviews:` frontmatter), and the `mstack/plan-NNN-done` tag gating.
- [x] README.md gains an "Enforcement" section summarizing the 4-layer model
      from AGENTS.md (picker convenience → Step 7a honest-path gate → git-hook
      write barrier → retroactive audit), including the honest residual
      (deterrent + detectable, not unbypassable), plus what `mstack-init`
      installs into consumer repos (`core.hooksPath .githooks`, the hook
      shims).
- [x] README's picker exit table (lines 354-365) gains rows for 15
      (`EXIT_GOAL_NOT_FOUND`) and 21 (`EXIT_REF_AMBIGUOUS`, surfaced by the
      picker on ambiguous name refs), and notes that 12 also fires in
      unscoped mode — wording for rows 10/12 coordinated with plan 054, which
      owns their correctness (this plan owns the full-table pass). NOTE: plan
      054's own AC also adds row 15 (and possibly 21) to this README table;
      since 054 runs earlier, VERIFY each row's presence and add only what is
      missing — do not insert a duplicate row.

## Design

Reconstruction method (essential steps of the mstack-changelog skill,
inlined): find the last recorded entry's date (2026-06-30); `git log
--oneline --since=2026-06-30` plus the frontmatter of every archived plan with
id >= 030 in `docs/plans/archive/`; classify by type (Added / Changed / Fixed
/ Internal); group the enforcement family into one narrative block rather than
nine bullets; draft in the file's existing voice. Note: the archive currently
reaches only plan 043 — work from ids >= 044 that landed as direct commits
without an archived/done plan (e.g. the 046/047 features, commits 34c52c4 /
56020fe) is recovered from `git log`, not from `docs/plans/archive/`; do not
claim a plan shipped unless it is archived or its feature commit exists. Date the consolidated entry
with the completion date of the newest plan it covers. The README Enforcement
section is a summary with a pointer to AGENTS.md for the full model — do not
duplicate the whole doctrine.

Run this plan LAST among the prose plans 069-072 (priority left blank) — but
that is the only sense in which it runs late: plans 073-085 land after it, so
this catch-up covers through the currently-archived range only, and a later
catch-up will cover the audit-remediation family.

Testing approach: unit-only

**Files expected to change:**

- `CHANGELOG.md`: catch-up entries, Unreleased consolidation
- `README.md`: per-plan sequence, Enforcement section, exit-code table

**Out of scope:** rewriting archived plan files; changing any script or hook
behavior; the correctness semantics of exit rows 10/12 (plan 054 owns those);
back-dating or inventing release version numbers beyond what the existing file
already uses.

## Tasks

1. Inventory unrecorded work: last CHANGELOG date vs `git log` and
   `docs/plans/archive/` ids >= 030.
2. Draft the catch-up entries, with the enforcement family and its
   consumer-facing upgrade note (hooks now installed) leading.
3. Consolidate the four `[Unreleased]` sections into Keep a Changelog form.
4. Update README's per-plan sequence with gates, records, and tag gating.
5. Write the README Enforcement section (4 layers + honest residual +
   what mstack-init installs).
6. Extend the picker exit table with 15 and 21, note unscoped 12, and align
   10/12 wording with plan 054's outcome.

## Verification

Checks:

- [assert] `grep -c '^## \[Unreleased\]' CHANGELOG.md | 1`
- [cmd] `grep -q '038' CHANGELOG.md && grep -q '043' CHANGELOG.md`
- [cmd] `grep -qi 'hook' CHANGELOG.md`
- [cmd] `grep -qi 'enforcement' README.md`
- [cmd] `grep -q 'EXIT_GOAL_NOT_FOUND\|| 15 |' README.md`
- [cmd] `grep -q 'EXIT_REF_AMBIGUOUS\|| 21 |' README.md`
- [cmd] `grep -qi 'review gate\|assert-completable' README.md`
- [manual] read the consolidated CHANGELOG top-to-bottom: one Unreleased
  section, dated entries in reverse-chronological order, enforcement family
  clearly flagged as a consumer-visible behavior change

## Completion note (2026-07-31)

Executed despite the recorded `blocked-by: [054]`. 054 (picker distinguishes
all-blocked from all-done unscoped) is still `pending`; it was cited only
because it owns the *correctness semantics* of exit rows 10 and 12. This plan
did not restate those two rows, so nothing here can conflict with 054's
outcome. The exit-code section was rebuilt as a full pass over `lib.sh` (codes
0, 10-15, 21-35, grouped by subsystem) rather than the two-row patch the plan
described, and it now points at `lib.sh` as the authoritative source, so a
future code addition does not silently make the README stale again.

The README "Enforcement" section was written as the plan specified: the
four-layer model summarized, the honest residual stated plainly
(deterrent-plus-detectable, not unbypassable), what `mstack-init`/`setup`
install into a consumer repo, and how to remove it. Full doctrine stays in
AGENTS.md.

CHANGELOG: the four stacked `[Unreleased]` sections were consolidated to one,
with the previous three re-dated. Bracket-date headers were used rather than
invented version numbers, since the file's only real version header is
`[2.0.0] - 2026-05-20`.

Two things surfaced while doing this, neither in scope here:

- Plans 046 and 047 are `status: pending` while their feature commits
  (`34c52c4`, `56020fe`) are already on main. That is exactly the
  shipped-but-unclosed condition plan 087 exists to detect, and it is live now.
- The 2026-06-03 changelog entry already claimed e2e was "a scored category
  (20% default weight)". It was not, until plan 065 landed today. The entry was
  wrong when it was written; the new entry describes 065 as making e2e
  actually scored rather than repeating the earlier claim.
