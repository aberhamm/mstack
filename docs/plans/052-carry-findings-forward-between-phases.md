---
id: 052
title: carry findings forward between pipeline phases instead of re-deriving them
status: pending
blocked-by: [049]
priority:
goal: pipeline-hardening
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
---

## Requirements

Doctor, review, and every codex call start cold, so the same facts get
re-derived repeatedly within one session — the import count, the provider enum,
the conftest gating were each rediscovered several times across phases working
the same goal. The cost is both wall-clock and inconsistency: two phases can
derive slightly different versions of the same fact and neither notices.

**Acceptance criteria**

- [ ] A per-`goal:` findings file that phases append to and read.
- [ ] Each entry records: the fact, the phase that derived it, the file(s) it
      was derived from, and the content hash of those files at derivation time.
- [ ] **Staleness is enforced, not hoped for.** A carried-forward finding whose
      source files have changed since derivation is marked STALE and is not
      served as current. A stale finding presented as fresh is worse than no
      finding — it is a confident wrong answer.
- [ ] A reader can always ignore the file and re-derive; nothing depends on it
      for correctness.
- [ ] Smoke coverage: append and read back; a source-file edit marks the entry
      STALE; a corrupt file degrades to empty rather than erroring the phase.

## Design

Same storage objection as 049 and the same answer: `.mstack/` is gitignored, so
this is per-machine and gone on a fresh clone. That is acceptable **only**
because every entry is reconstructible by re-deriving. Nothing that is not
reconstructible may be stored here — if a phase produces durable knowledge, it
belongs in a committed doc (plan 044's rule), not in this cache.

`blocked-by: [049]` because 049 establishes the artifact conventions —
hash-keying, corrupt-file fallback, announced reuse. Building a second,
differently-shaped cache first would guarantee two incompatible ones.

Staleness uses the same content-hash mechanism as 049 rather than timestamps:
timestamps cannot distinguish "file touched" from "file changed", and a
false-fresh finding is the failure that matters.

**Files expected to change:**

- `skills/mstack-run/scripts/findings-log.sh`: new; `append` / `read <goal>`
  with hash-based staleness marking.
- `skills/mstack-run/scripts/findings-log-smoke.sh`: new.
- `skills/mstack-plan-doctor/SKILL.md`: read before deriving, append after.
- `AGENTS.md`: state the reconstructible-only rule for this store.

**Out of scope:** storing durable project knowledge here (that is a committed
doc, per plan 044); cross-goal or cross-session sharing; making any phase
*depend* on the log being present.

## Tasks

1. Write `findings-log.sh` with append/read and hash-based staleness.
2. Write the smoke suite: round-trip, staleness on edit, corrupt-file fallback.
3. Wire read-before-derive and append-after into plan-doctor.
4. Document the reconstructible-only rule.

## Verification

Checks:

- [cmd] `test -f skills/mstack-run/scripts/findings-log.sh`
- [cmd] `test -x skills/mstack-run/scripts/findings-log.sh`
- [cmd] `bash skills/mstack-run/scripts/findings-log-smoke.sh`
- [assert] `grep -c "STALE" skills/mstack-run/scripts/findings-log.sh`
- [cmd] `grep -q "reconstructible" AGENTS.md`
- [manual] confirm editing a source file marks the derived finding STALE
