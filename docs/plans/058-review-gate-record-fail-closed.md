---
id: 058
title: make record fail closed on unwritable frontmatter and validate review-required tokens
status: pending
blocked-by: []
priority: 24
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
---

## Requirements

Two confirmed fail-open bugs in `skills/mstack-run/scripts/review-gate.sh`,
both reproduced by live probes in temp repos.

(a) `cmd_record`'s rewriting awk (lines 626-647) only inserts the built
`reviews:` block when it sees the SECOND `---` fence (`fm==2 && !printed`). A
plan whose frontmatter is unclosed or missing gets NOTHING inserted — yet the
awk exits 0, the `mv` lands, line 654 prints `recorded: <type>=<verdict> ...`,
and the command exits 0. The single most safety-critical write in the
enforcement layer silently loses a verdict while reporting success.

(b) **DEFERRED — not in this plan's scope. See the Backlog amendment below.**
Retained for the record: `cmd_record` validates its own `type` argument (line
573, `eng|design|ceo|code`), but nothing validates the tokens inside
`review-required:` frontmatter, so `review-required: security` — or a typo like
`enng` — creates a gate no sanctioned actor can clear, since `record` rejects
the type and hand-editing `reviews:` is forbidden by plan 035.

**Correction (2026-08-06):** the original framing of (b) — "permanently
non-completable with no legible diagnosis" / "silently forever-open" — is
FALSE, and was the premise the deferral rested on. Verified against source:
`cmd_required` emits the bogus token, `_completable_check` (`review-gate.sh:202-214`)
loops it, `_type_cleared` finds no passing record, and the function returns 1
after printing `not completable: review 'security' has no passing record`. That
is fail-CLOSED with a legible diagnostic. (b) is a stuck-plan UX papercut — a
confusing message rather than a wrong one — not a safety hole.

**Acceptance criteria** (part (a) only — (b) is deferred)

- [ ] `record` against a plan with unclosed/missing frontmatter exits nonzero
      via `die`, leaves the plan file byte-identical, and never prints
      `recorded:`.
- [ ] After any successful rewrite, `record` re-reads the file via
      `review_entries` and `die`s if the just-recorded entry is absent
      (belt-and-suspenders on the awk exit signal).
- [ ] `review-gate-smoke.sh` gains cases for part (a) and for the absorbed
      `assert-committed` / `assert-work-committed` regressions (see the Triage
      amendment), and all suites pass.

**Deferred, do NOT implement here:** token validation in `cmd_required` /
`_raw_required`. It is preserved in the Design section below for whoever
reopens it.

## Design

For (a): give the awk an `END { if (!printed) exit 3 }` block so a run that
never emitted the block signals failure; the existing `else` branch (line
649-652) already `die`s on nonzero awk exit and removes the temp file. Then,
after `mv`, re-read with `review_entries "$abs"` and grep for the exact
`type=$type verdict=$verdict` pair; `die "record: verify-after-write failed"`
if absent. Two independent signals — the awk's own accounting and an
end-to-end read-back — so neither is a single point of silent failure
(AGENTS.md plan-045 doctrine).

For (b) — **DEFERRED, retained as the design for whoever reopens it; do not
implement it in this plan.** Note the propagation caveat below is the reason
(b) was judged expensive relative to its payoff, and it remains the hard part:
add a validation loop in `cmd_required` and `_raw_required` — after
`_types_of` expansion, any token not in `eng|design|ceo|code` is a `die`
naming the token, the file, and the valid set. CRITICAL propagation caveat
(verified live): `set -e` does NOT make this fail closed on its own. Every
consumer of `$(cmd_required ...)` that matters — `_completable_check` (called
as `if _completable_check` / `if ! _completable_check` from
`cmd_assert_completable`, `cmd_hook_pre_commit`, `cmd_hook_pre_push`) — runs
with `set -e` SUSPENDED for its whole body (bash condition-context rule), so
the die exits only the substitution subshell, the assignment failure is
ignored, `required` comes back empty, and `[ -n "$required" ] || return 0`
reads the garbled plan as COMPLETABLE — the exact fail-open this plan
abolishes. Therefore each assignment site must check the substitution status
explicitly: `required="$(cmd_required "$file")" || { echo "not completable:
invalid review-required declaration in $file" >&2; return 1; }` in
`_completable_check`, and the same pattern anywhere else `cmd_required` /
`_raw_required` output is captured inside a conditionally-invoked function.
`cmd_audit`'s capture runs under active `set -e` (direct dispatch), so a
garbled CURRENT plan hard-aborts the whole audit until plan 060 rewrites it
with lenient per-plan handling and exit-code-aware status.sh — acceptable
interim (the abort is nonzero, i.e. closed, not open).
`needs-review`-derived tokens flow through the same check (its legal tags are
a subset).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: awk END guard + read-back in
  `cmd_record`; token validation in `cmd_required`/`_raw_required`.
- `skills/mstack-run/scripts/review-gate-smoke.sh`: new cases.

**Out of scope:** the downgrade-detection laundering hole (plan 059), audit
history recovery (plan 060), any change to the hooks' shipped source, any
change to `record`'s replace-in-place semantics (plan 062 owns supersession).

## Tasks

1. Add the `END { if (!printed) exit 3 }` guard to the `cmd_record` awk and
   confirm the existing failure branch cleans up and `die`s.
2. Add the post-`mv` read-back via `review_entries` + `die` on absence.
3. ~~Token validation in `cmd_required` / `_raw_required`.~~ **DEFERRED — do
   not implement.** See the Backlog amendment and the Requirements correction.
4. Extend `review-gate-smoke.sh`: (i) a temp plan with no closing `---` fence —
   `record` exits nonzero, file unchanged (compare before/after checksums),
   no `recorded:` on stdout; (ii) positive control: a valid plan still records
   and clears exactly as before; (iii) the absorbed regressions from the Triage
   amendment — `assert-committed` (exempt with no reviews entry, exit 25 when a
   recorded verdict sits dirty) and `assert-work-committed` (exit 28 on
   plan-attributable dirt, fail-closed on a missing baseline).
5. Run the full smoke set and shell lint.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `grep -c "verify-after-write" skills/mstack-run/scripts/review-gate.sh` — the post-mv read-back die exists (note: a grep on `printed` would be vacuous — that flag already appears 3x pre-implementation)
- [assert] `bash skills/mstack-run/scripts/review-gate-smoke.sh 2>&1 | grep -i "unclosed\|assert-committed\|assert-work-committed"` — the part-(a) and absorbed-regression cases run. Deliberately does NOT grep for "invalid token" / "security": that is deferred part (b), and a check naming output this plan will never produce is a check that can only fail.

## Backlog amendment (2026-07-31)

SCOPE NARROWED. Ship part (a) only: make `record` fail closed when
frontmatter has no closing fence. Verified failure — the awk emits the block
only at `fm==2`, so a plan with an unclosed fence returns rc=0, prints
"recorded: eng=approved", and leaves the file byte-identical. An awk END
guard plus a read-back is roughly 15 lines.

Part (b), validating `review-required` tokens, is DEFERRED and should not
block this plan. A typo already fails CLOSED — `review-required: security`
makes `assert-completable` exit 23 with a legible diagnostic and `record`
refuse the type. It is a stuck-plan UX papercut, not a safety hole, and it
introduces a new `die` whose propagation through `_completable_check` is the
subtle part of this plan. Land (a) alone; reopen (b) separately if it ever
bites.

**Reconciliation (2026-08-06).** This amendment narrowed the scope but the
Requirements, Acceptance criteria, Design, Tasks, and Verification above still
described part (b) as in-scope — 120 lines above the amendment that retired it.
A worker reads the acceptance criteria as its test oracle and would have
implemented the deferred half. Those sections are now reconciled with this
amendment, and (b)'s false "silently forever-open" premise is corrected in
place (it fails closed and says why). Found by the plan-090 premise-attack
brief on its first live run; nothing about the narrowing decision itself
changed.

## Triage amendment (2026-07-31)

ABSORBS the `assert-committed` / `assert-work-committed` regression
cases from plan 063, which is dropped. Those two assertions run on every plan
and have zero coverage today; the residual belongs in the existing
`review-gate-smoke.sh` rather than in an eighth suite requiring registration in
the shipped hook source, the `.githooks/` copy, and AGENTS.md.

Add to this plan acceptance criteria: `review-gate-smoke.sh` gains cases for
`assert-committed` (exempt when no reviews entry, exit 25 when a recorded
verdict sits dirty) and `assert-work-committed` (exit 28 on plan-attributable
dirt, fail-closed on a missing baseline file). The pre-push rejection paths from
063 are NOT carried — this workflow does no automatic push, so they are the
least-exercised code in the enforcement layer.
