---
id: 020
title: Document resilience mechanism
status: done
blocked-by: [019]
allows-migrations: false
needs-review: none
created: 2026-06-05
completed: 2026-06-05
reviewed: false
qa: automated
---

## Requirements

The new resilience mechanism (distinct picker exit codes, execution manifest,
anomaly detection, auto-handoff) needs user-facing documentation so users
understand what happens when things go wrong during autonomous execution and
how to recover.

**Acceptance criteria:**

- [ ] README.md has a section explaining the resilience mechanism in plain language
- [ ] Picker exit codes are documented with their meaning and when they fire
- [ ] Common anomaly scenarios are listed with recovery steps
- [ ] The execution manifest (.mstack/execution-manifest.json) is explained: what it is, when it's created/deleted, what to do if a stale one is found
- [ ] CHANGELOG.md updated with the new feature

## Design

**README.md updates:**

Add a new section "Resilience during autonomous execution" (or update the
existing execution-related section) covering:

1. Three-layer defense: upfront validation, manifest tracking, anomaly detection
2. What happens when a plan file is moved/renamed/reordered during execution
3. The ANOMALY signal and automatic handoff checkpoint
4. How to resume after an anomaly: `resume from handoff <name>`

**Troubleshooting scenarios to document:**

| Scenario | What happens | Recovery |
|----------|-------------|----------|
| Plan ID typo in /goal command | Upfront validation catches it, refuses to start | Fix the ID and re-run |
| Plan file renamed during execution | Path divergence detected, anomaly handoff | Resume from handoff, check plan files |
| Plan stuck in-progress | Iteration bound hit, anomaly handoff | Check plan status, re-run or mark failed |
| Dependency cycle | Picker exits 13, goal stops | Fix the cycle in plan frontmatter |
| Stale manifest from crashed session | Warning logged, overwritten | No action needed (auto-recovered) |

**Files expected to change:**

- `README.md`: add/update resilience section
- `CHANGELOG.md`: add entries for plans 016-019

**Out of scope:** API documentation, inline code comments. The code is
self-documenting via exit code constants and manifest schema.

Testing approach: unit-only

## Tasks

1. Draft README.md resilience section explaining the three-layer defense in plain language
2. Add picker exit code reference table to README.md
3. Add troubleshooting table with common anomaly scenarios and recovery steps
4. Add execution manifest explanation (what, when, cleanup)
5. Update CHANGELOG.md with new entries for the resilience feature

## Verification

Checks:
- [cmd] grep -qE "resilience|anomaly|execution manifest" README.md
- [cmd] grep -qE "exit.code|EXIT_" README.md
- [assert] grep -cE "016|017|018|019" CHANGELOG.md | awk '{print ($1 >= 1) ? "PASS" : "FAIL"}' | grep PASS
