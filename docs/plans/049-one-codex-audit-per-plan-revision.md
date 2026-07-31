---
id: 049
title: run one codex audit per plan revision instead of one per skill
status: skipped
blocked-by: []
priority:
goal: pipeline-hardening
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
skipped: 2026-07-31
skipped-reason: "backlog optimization: optimizes the planning pipeline (runs in bursts) while execution runs continuously; plan refutes its own headline saving"
---

## Requirements

`mstack-plan-doctor` Step 3.5 (adversarial audit) and gstack `plan-eng-review`
("Outside Voice") **both** shell out to `codex exec --sandbox read-only` with
near-identical falsify-first prompts. Verified by reading both call sites, not
inferred. A doctor→eng-review sequence on one plan therefore pays for two full
codex runs, and the second largely rediscovers the first's findings.

Measured: **~3 minutes per codex run.** Observed twice on one plan (078) in a
single session, with the second run resurfacing findings the first had already
produced. Claimed saving on any doctor→review sequence: roughly 40%.

**Acceptance criteria**

- [ ] Doctor writes its audit findings to an artifact keyed by **plan id +
      content hash** of the plan file.
- [ ] A later audit request for the same plan at the same hash reuses the stored
      findings instead of re-running codex.
- [ ] Any edit to the plan changes the hash and forces a fresh run — a stale
      audit must never be served for changed content.
- [ ] Reuse is **announced**, not silent: output states the findings are reused
      and names the hash, so a reader can tell a cached audit from a fresh one.
- [ ] Cache miss, unreadable artifact, or hash mismatch all fall back to running
      codex. The cache is an optimization and never a source of truth.
- [ ] Smoke coverage: same hash reuses; changed plan re-runs; corrupt artifact
      falls back cleanly.

## Design

The reader is the hard part, and it is a **cross-repo coupling question, not a
caching question**. `plan-eng-review` is a **gstack** skill living outside this
repo; mstack cannot make it read an mstack artifact by fiat. Two options, and
the plan must pick one explicitly rather than assume:

- **(a) mstack-side only.** Doctor caches; only mstack readers benefit.
  Self-contained, ships today, saves nothing on the doctor→eng-review path that
  motivated this — which is most of the claimed 40%.
- **(b) documented artifact contract** that gstack's eng-review may opt into,
  with an upstream change there. Captures the real saving; needs coordination
  and a stable published format.

Recommendation: build (a) with the artifact format **specified as a public
contract from day one**, so (b) becomes an upstream read rather than a redesign.

Storage caveat, and it is the same objection as plan 044: `.mstack/` is
gitignored, so the artifact is per-machine and gone on a fresh clone. Acceptable
for a cache — a lost cache costs 3 minutes, not correctness — but it must never
hold anything not reconstructible by re-running.

**Files expected to change:**

- `skills/mstack-run/scripts/audit-cache.sh`: new; `get`/`put` keyed by plan id
  + content hash, storing under `.mstack/audits/`.
- `skills/mstack-run/scripts/audit-cache-smoke.sh`: new.
- `skills/mstack-plan-doctor/references/adversarial-audit.md`: consult the cache
  before spawning codex; announce reuse.
- `docs/audit-artifact-contract.md`: new; the published format, so an external
  reader can adopt it without reverse-engineering.

**Out of scope:** modifying gstack (option (b) is a separate, coordinated
change); caching anything other than codex audit findings; sharing the cache
between machines.

## Tasks

1. Write `audit-cache.sh` (get/put, hash keying, corrupt-artifact fallback).
2. Document the artifact contract.
3. Wire the cache into the doctor audit path with an explicit reuse announcement.
4. Write the smoke suite: hit, miss-on-edit, corrupt-fallback.

## Verification

Checks:

- [cmd] `test -f skills/mstack-run/scripts/audit-cache.sh`
- [cmd] `test -x skills/mstack-run/scripts/audit-cache.sh`
- [cmd] `bash skills/mstack-run/scripts/audit-cache-smoke.sh`
- [cmd] `test -f docs/audit-artifact-contract.md`
- [assert] `grep -c "reused" skills/mstack-plan-doctor/references/adversarial-audit.md`
- [manual] confirm an edited plan visibly re-runs codex rather than serving a cached audit
