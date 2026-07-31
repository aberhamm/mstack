---
id: 060
title: make audit recover the declared required set from git history
status: skipped
blocked-by: [062]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
skipped: 2026-07-31
skipped-reason: "backlog optimization: git archaeology against an adversary AGENTS.md declares out of scope; two cheap fail-open fixes salvaged into 068"
---

## Requirements

Confirmed hole in layer 4. `cmd_audit` (review-gate.sh lines 762-792) derives
each done/archived plan's required set from CURRENT file content via
`cmd_required`. A single `--no-verify` commit that both marks a plan done AND
sets `review-required: none` (or plan 059's laundering applied to a legacy
plan) defeats layers 3 and 4 together: the hook was skipped and the audit
reads the laundered declaration as "explicitly nothing required" — no evidence
trail ever exists. This contradicts AGENTS.md's claim that the audit "catches
the two ways layer 3 can be evaded" (`--no-verify` and out-of-band edits).

Two adjacent fail-opens, also confirmed:
`pdir="$(plans_dir 2>/dev/null)" || exit 0` (line 764) makes a wrong-cwd
invocation read as all-clean, and `status.sh` line 240
(`audit_out="$(bash ... audit 2>/dev/null || true)"`) branches on stdout text,
so an audit CRASH prints nothing and reads as verified.

**Acceptance criteria**

- [ ] For each done/archived plan, audit recovers the declared required set
      from HISTORY: plan content at the `mstack/plan-<id>-done` tag when the
      tag exists, else at the first commit where `status:` became `done`;
      falls back to current content only when neither exists, and says so.
- [ ] Audit flags (i) recovered-required types lacking a passing record in the
      CURRENT file, and (ii) a required set shrunk since completion
      (recovered set not a subset of the current effective set) as distinct
      finding kinds.
- [ ] Plan 062 supersede semantics are honored: newest-record-per-type, and a
      preserved demotion chain is never flagged as tampering (though an
      unresolved newest `changes-requested` on a done plan IS an offender).
- [ ] "No plans dir" exits a distinct nonzero code with a diagnostic — never 0.
- [ ] `status.sh` branches on the audit EXIT CODE: 0 = clean, 27 = offenders
      listed, anything else = "audit could not run — NOT verified" warning.
- [ ] The AGENTS.md honest-residual paragraph is updated to match what audit
      now actually catches (a completion-time laundering edit no longer
      escapes it; simultaneous history rewrite remains out of scope).

## Design

Add `_required_at_completion <relpath> <id>`: (1) if
`git rev-parse -q --verify "refs/tags/mstack/plan-<id>-done"` succeeds, read
the plan blob at that commit — try the current relpath, then the non-archive /
archive twin of it, then scan the tag commit's `docs/plans` tree for the file
whose `fm_get id` matches (archive moves change the path after tagging);
(2) else walk the file's history and find the FIRST (oldest) commit whose blob
has `status: done` (via `fm_get` on `git show <sha>:<path>`; `--follow` needs
the per-commit path, so capture sha+path pairs from
`git log --follow --name-status`). Caution: `--follow` combined with
`--reverse` is a known-flaky git pairing (rename tracking assumes
newest-first traversal) — walk newest-first WITHOUT `--reverse` and take the
LAST matching sha+path pair, which is the oldest; (3) else fall back to current
content and mark the finding line "(required set from current content —
no completion history)". Apply the required-set derivation of `cmd_required`
(explicit field, else `needs-review`) to the HISTORICAL blob, and 058's token
validation leniently here: an invalid historical token is reported as an
offender, not a crash, so one garbled plan cannot abort the whole audit. The
same leniency MUST cover the CURRENT-content reads inside `cmd_audit` (the
`$(cmd_required "$f")` capture and the current-effective-set side of finding
(ii)): after 058, `cmd_required` `die`s on an invalid token, and under
`cmd_audit`'s active `set -e` that one capture would abort the entire scan —
use a lenient in-audit derivation (or capture with `|| { flag offender;
continue; }`) so a garbled plan becomes a finding, never an abort.

Exit contract: define `EXIT_GATE_AUDIT_UNAVAILABLE=35` in lib.sh (next free
code after 34; keep clear of pick-next 10-19, seam-check 20, resolve 21-22,
gate 23-28, wrapup 29, health 30-31, scaffold 32, verify 33, reach 34). Audit
exits 35 when it cannot run (no plans dir, not a git repo); 27 stays
"offenders found"; 0 stays clean. `status.sh` drops the `2>/dev/null || true`
swallow, captures the exit code, and renders three distinct states; 27 must
not crash status (`set -e` guard around the call).

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/review-gate.sh`: `_required_at_completion`,
  `cmd_audit` rewrite.
- `skills/mstack-run/scripts/lib.sh`: `EXIT_GATE_AUDIT_UNAVAILABLE=35`.
- `skills/mstack-run/scripts/status.sh`: exit-code branching at ~line 240.
- `skills/mstack-run/scripts/review-gate-smoke.sh`: audit cases (clean,
  laundered, no-history fallback, unavailable).
- `AGENTS.md`: honest-residual paragraph in "Layered Enforcement Model".

**Out of scope:** doctor's audit surfacing (it shells the same subcommand and
inherits the fix), the hooks, detecting history REWRITES (filter-branch), any
new audit for uncommitted work (plan 039 explicitly rules that out).

## Tasks

1. Implement `_required_at_completion` with the tag-first, done-commit-second,
   current-content-last resolution and the archive-twin path handling.
2. Rewrite `cmd_audit` to use it, emit the two finding kinds with `plan_label`
   citations, honor newest-record-per-type from plan 062.
3. Replace the line-764 `|| exit 0` with a diagnostic + exit 35; add the code
   to lib.sh with a comment in the existing reserved-sequence style.
4. Fix `status.sh` to branch on exit code (0 / 27 / other), with the "other"
   branch printing the NOT-verified warning including the actual code.
5. Smoke, in a throwaway repo: (i) properly completed plan (tag + records) —
   audit clean; (ii) `--no-verify`-style completion that sets
   `review-required: none` in the same commit — audit flags it via the tag
   blob; (iii) same but no tag, recovery via first done-commit; (iv) audit from
   a dir with no plans → exit 35; (v) preserved 062 demotion chain with final
   re-approval → clean.
6. Update AGENTS.md and run the full smoke set + shell lint.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/status.sh skills/mstack-run/scripts/lib.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/status.sh skills/mstack-run/scripts/lib.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/hook-chain-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [assert] `grep -c "EXIT_GATE_AUDIT_UNAVAILABLE" skills/mstack-run/scripts/lib.sh` — new exit code defined
- [assert] `grep -c "NOT verified" skills/mstack-run/scripts/status.sh` — status renders the could-not-run state
- [cmd] `bash skills/mstack-run/scripts/status.sh`
