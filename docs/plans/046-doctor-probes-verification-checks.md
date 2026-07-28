---
id: 046
title: plan-doctor probes verification checks instead of just counting them
status: pending
blocked-by: []
priority:
goal:
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-29
qa: automated
---

## Requirements

`mstack-plan-doctor` validates that a plan's `## Verification` section contains
at least one `[cmd]`/`[assert]`/`[status]` check. That test is **existence, not
workability**, and it is performed by an LLM subagent reading prose — nothing in
mstack parses these checks deterministically today.

So a plan can pass validation while its test oracle is dead on arrival:

- `python manage.py scan --dry-run --sites all` — neither flag exists on the CLI;
- `pytest tests/ -m browser -q` — the selector collects **zero** tests and exits
  0, so the check goes green while testing nothing;
- `test -n "$(ls docs/ -R | grep -i gpu)"` — matches nothing, because the docs it
  asserts on were never written;
- `test -f <path>` — on a path no task creates.

Each was caught by a human reading five plans. Each was detectable by
**execution**, in seconds, with no model reasoning. This is the same failure
family the 043/045 work already addressed from other angles: *a check that
cannot run is not a check that passed.*

**Acceptance criteria**

- [ ] `verify-lint.sh probe <plan>` extracts the declared checks and reports each
      as OK / BROKEN / SUSPECT / UNPROBED / SKIP.
- [ ] Exit `EXIT_VERIFY_BROKEN` (33) when any check is provably broken; 0
      otherwise. UNPROBED never contributes to the exit code.
- [ ] **A check is executed only when proven read-only.** Every command head —
      the first word plus the first word after any `|`, `;`, `&&`, `||`, `$(`,
      `(` — must be on an allowlist, and no redirect or backtick may appear.
      Anything else is UNPROBED.
- [ ] A pytest check that collects zero tests is BROKEN, not OK.
- [ ] A CLI flag appearing nowhere in the repo is reported SUSPECT (heuristic,
      non-blocking) — the only safe handle on the "flag does not exist" class,
      since probing it would mean executing project code.
- [ ] The summary states plainly that UNPROBED is not a pass.
- [ ] `plan-doctor` runs the probe per plan; BROKEN is a blocking finding for the
      Step 4b gate, SUSPECT and UNPROBED are reported and do not block.
- [ ] `verify-lint-smoke.sh` covers detection, the injection cases, and the
      pytest paths, and is wired into the commit-time suite run.

## Design

### Safety is the load-bearing part

Check strings come out of a markdown file any agent can write, so the classifier
is a **security boundary**, not a convenience. A prefix match is not enough:
`grep foo bar; rm -rf ~` starts with `grep`. The rule is fail-closed — allowlist
every command head, ban redirects and backticks, and treat everything else as
UNPROBED. `eval` is then used deliberately to honor quoting (`grep 'two words' f`)
on a string already proven to contain no substitution, chaining, or redirect.

Deliberately excluded from the allowlist despite looking harmless: `sed` (`w`
writes files), `awk` (`system()`), `find` (`-exec`/`-delete`), `xargs`, `env`,
`sh`/`bash`, and every language runtime. `pytest` is excluded too — it gets the
`--collect-only` path rather than being run as written.

### Three states, and the third is the point

OK / BROKEN are the easy half. **UNPROBED must be reported as not-verified and
never read as approval** — an unprobed check silently treated as fine is exactly
the defect this plan exists to remove, rebuilt one layer up. Hence the summary
line: `UNPROBED is NOT a pass.`

**Files expected to change:**

- `skills/mstack-run/scripts/verify-lint.sh`: new, the probe.
- `skills/mstack-run/scripts/verify-lint-smoke.sh`: new, the suite.
- `skills/mstack-run/scripts/lib.sh`: `EXIT_VERIFY_BROKEN=33`.
- `skills/mstack-plan-doctor/SKILL.md`: Step 3.7 wiring + finding semantics.
- `skills/mstack-run/hooks/pre-commit` + `.githooks/pre-commit`: add the suite.
- `AGENTS.md`: list the suite.

**Out of scope:** probing `[status]` (network) and `[browse]` (needs a running
app); executing project code to enumerate real CLI flags; the other five items
from the same review (codex de-duplication, parallel fan-out, repo-invariant
checks, `review.autonomy`, cross-phase findings carry-forward) — each is its own
plan.

## Tasks

1. Add `EXIT_VERIFY_BROKEN=33` to `lib.sh`.
2. Write `verify-lint.sh`: extract, classify, probe, report.
3. Write `verify-lint-smoke.sh`, including the injection canary cases.
4. Wire Step 3.7 into `plan-doctor`, and the suite into the commit gate.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/verify-lint-smoke.sh`
- [cmd] `test -f skills/mstack-run/scripts/verify-lint.sh`
- [cmd] `test -x skills/mstack-run/scripts/verify-lint.sh`
- [assert] `grep -c "UNPROBED is NOT a pass" skills/mstack-run/scripts/verify-lint.sh`
- [cmd] `grep -q "verify-lint-smoke" skills/mstack-run/hooks/pre-commit`
- [cmd] `grep -q "Step 3.7" skills/mstack-plan-doctor/SKILL.md`
- [manual] confirm BROKEN reads as blocking and UNPROBED as not-a-pass in the doctor report
