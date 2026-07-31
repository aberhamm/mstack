---
id: 050
title: fan out external model calls at session start instead of per plan
status: skipped
blocked-by: [049]
priority:
goal: pipeline-hardening
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
skipped: 2026-07-31
skipped-reason: "backlog optimization: parallel fan-out already shipped in prose; speedup baseline measures instructions being ignored"
---

## Requirements

Codex audits are read-only and independent of one another, but each is gated
behind a section of a skill, so they run essentially serially. Observed: **nine
audits across one session ran one after another**. Firing them in parallel at
session start would collapse **25+ minutes into roughly 4**. Done by hand for
the last two reviews of that session and reported as dramatically faster.

Nothing about the work requires serialization — only the prose structure of the
skills does.

**Acceptance criteria**

- [ ] A single entry point audits N plans concurrently, with a bounded
      concurrency cap rather than N unbounded processes.
- [ ] Results land in the plan-049 audit cache, keyed by plan id + content hash,
      so the consuming skill step reads instead of re-running.
- [ ] One plan's failure, timeout, or malformed output never blocks the others:
      that plan is reported audit-inconclusive and the rest proceed.
- [ ] An inconclusive audit is reported as such and is **never** rendered as
      "clean" — an audit that did not run is not an audit that passed.
- [ ] Wall-clock for N plans is materially below N × single-plan time, measured
      and recorded, not asserted.

## Design

This is why 049 comes first: parallel fan-out needs somewhere to put results
before the consuming step exists. Without the cache, early results have no home
and the work is thrown away. `blocked-by: [049]` is a real ordering constraint,
not bookkeeping.

Concurrency is capped (default 4) because each codex process is a paid external
call with its own memory and rate-limit envelope; unbounded fan-out on a large
backlog is a self-inflicted outage. The cap is configurable.

Failure isolation follows the existing rule in
`references/adversarial-audit.md`: nonzero exit, timeout, empty or malformed
output, or a finding with no `file:line` all mark that plan inconclusive without
touching the others.

**Files expected to change:**

- `skills/mstack-run/scripts/audit-fanout.sh`: new; `run <plan> [<plan>...]`,
  bounded concurrency, per-plan status, writes through `audit-cache.sh`.
- `skills/mstack-run/scripts/audit-fanout-smoke.sh`: new; uses stub binaries so
  the suite never makes a real external call.
- `skills/mstack-plan-doctor/SKILL.md`: optional warm-up step at session start.
- `skills/mstack-run/scripts/config.sh`: read the concurrency cap.

**Out of scope:** parallelizing anything that WRITES (only read-only audits
qualify); changing the audit prompt or rubric; speculative auditing of plans the
session will not touch — that trades wall-clock for spend.

## Tasks

1. Write `audit-fanout.sh` with a bounded worker pool and per-plan status.
2. Route results through `audit-cache.sh`.
3. Write the smoke suite against stub codex binaries, including one stub that
   fails and one that times out.
4. Add the optional warm-up step and the config key.

## Verification

Checks:

- [cmd] `test -f skills/mstack-run/scripts/audit-fanout.sh`
- [cmd] `test -x skills/mstack-run/scripts/audit-fanout.sh`
- [cmd] `bash skills/mstack-run/scripts/audit-fanout-smoke.sh`
- [assert] `grep -c "inconclusive" skills/mstack-run/scripts/audit-fanout.sh`
- [manual] measure wall-clock for 6 plans against 6 serial runs and record both
