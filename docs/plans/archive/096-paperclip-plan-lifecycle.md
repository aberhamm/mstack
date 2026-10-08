---
id: 96
title: Report plan and session lifecycle automatically
status: done
blocked-by: [93, 94, 95]
goal: paperclip-native-integration
allows-migrations: false
needs-review: none
review-required: eng,code
created: 2026-10-07
reviews:
  - type=eng verdict=approved date=2026-10-07 by=mstack-review
  - type=code verdict=pass date=2026-10-07 by=mstack-code-review
completed: 2026-10-07
reviewed: false
qa: automated
---

## Plain-English Summary

Once connected, users should see their existing mstack work advance in Paperclip without running a separate tracking command. Local plans and review gates remain authoritative.

**What changes in the code:** A small shared lifecycle entrypoint publishes authored plans and reports their verified transitions from authoring and orchestration skills.

## Requirements

- [ ] Create or adopt one remote task per repository/plan identity; archive moves and title changes preserve the mapping. Detect duplicate local plan IDs and ambiguous remote records instead of guessing.
- [ ] Publish successfully authored plans after plan-new/multi authoring completes, excluding templates; pending/blocked/deferred source state and restrictions remain visible without authorizing execution.
- [ ] mstack-run reports claim, blocked/failed, review and done at authoritative boundaries, with human ownership and actual session/worktree/commit/test metadata.
- [ ] Report done only after required reviews, health checks, committed work, archive and completion tag succeed; remote status never clears a local dependency or review gate.
- [ ] Handoff/wrap-up report continuation or actual outcome without inventing completion; mstack-status shows integration state and pending/conflicting delivery.
- [ ] Outage fixtures prove local execution/checkpointing survives while reporting remains visibly pending; conflict fixtures prove no accidental agent dispatch or stolen claims.
- [ ] Disabled integrations preserve the pre-integration behavior of all touched skills.

## Design

Testing approach: E2E

Build one deterministic lifecycle helper, not separate transports per skill. Implement and test mstack-run first, then thin authoring and reporting callers. Bind stable plan IDs to explicit repository identity; store adopted remote issue IDs in common Git integration state. Translate failed to a visible blocked remote record with local failed outcome preserved in notes because Paperclip has no assumed failed status. Treat completed reviewed local outcomes as done; implementation awaiting required review remains in_review. Remote manual changes and concurrent external ownership produce conflicts. Neither local outbox locks nor the board API promise cross-machine mutual exclusion.

**Lifecycle contract:** `paperclip_lifecycle.py emit --repo PATH --plan FILE --outcome STATE --json METADATA`, `reconcile --repo PATH --limit N`, and `status --repo PATH` call plan094 emit/reconcile/status. Outcomes are authored, claimed, blocked, failed, review, continuation and done. Common Git mappings persist repository_id/plan_id/issue_id and retain archive identity. Metadata includes authenticated human session label, absolute worktree, review/test evidence and actual completion-tag SHA for done. Report configured startup eligibility from plan095 once, only in interactive orchestrator sessions; no worker prompting.

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip_lifecycle.py`: new deterministic lifecycle/mapping helper
- `skills/mstack-run/SKILL.md`: authoritative lifecycle emit points
- `skills/mstack-plan-new/SKILL.md`: authored-plan publication
- `skills/mstack-plan-multi/SKILL.md`: approved authoring publication
- `skills/mstack-plan-doctor/SKILL.md`: reviewed/blocked source reporting
- `skills/mstack-handoff/SKILL.md`: continuation metadata
- `skills/mstack-wrap-up/SKILL.md`: verified outcome notes
- `skills/mstack-status/SKILL.md`: connection/pending visibility
- `skills/mstack-run/scripts/test_paperclip_lifecycle.py`: end-to-end fixture execution

**Out of scope:** container-agent dispatch, production code deployment, replacing local review/health gates, automatic Git branches, and secrets in tracked files.

## Tasks

1. Before editing load-bearing orchestration, characterize existing success/failure/archive/tag and review-gate behavior with isolated fixtures and preserve those fixtures as regression tests. Run a watched, scoped local smoke; after completion commit, rerun the tests independently because the changed gate is not independent evidence about itself.
2. Implement durable plan mapping and lifecycle payload generation.
3. Wire run claim/failure/review/completion at existing local boundaries.
4. Add thin publication and session/status callers.
5. Exercise normal execution, blocked reviews, archive failure, network outage and concurrent reporting fixtures.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_lifecycle.py -v
- [cmd] bash skills/mstack-run/scripts/review-gate-smoke.sh
- [cmd] bash skills/mstack-run/scripts/health-score-smoke.sh
- [manual] Run a watched, single disposable plan through the local orchestrator; after its commit rerun the lifecycle suite independently. Check the configured mode and actual observed behavior; do not claim remote delivery from a queued event.

<!-- mstack:seam
produced:
- kind: file; name: skills/mstack-run/scripts/paperclip_lifecycle.py; file: skills/mstack-run/scripts/paperclip_lifecycle.py
assumed:
- from: 093; kind: file; name: skills/mstack-run/scripts/paperclip_config.py; file: skills/mstack-run/scripts/paperclip_config.py
- from: 094; kind: file; name: skills/mstack-run/scripts/paperclip.py; file: skills/mstack-run/scripts/paperclip.py
-->

## GSTACK REVIEW REPORT

| Review | Runs | Status | Findings |
|---|---:|---|---|
| Architecture | 1 | PASS after amendments | Lifecycle helper binds stable IDs and reports done only after authoritative local archive/tag gates. |
| Code quality | 1 | PASS | Shared CLI contracts pinned; no duplicate transports or credential storage. |
| Tests | 1 | PASS for implementation | Pre-change characterization; watched single-plan smoke; post-commit independent lifecycle and gate suites. New code tests have not run yet. |
| Performance | 1 | PASS | Bounded requests/queues; no startup network for disabled modes. |
| Outside voice | 0 | UNAVAILABLE | Configured Codex CLI rejects gpt-6.1-sol with ChatGPT account; no outside clearance claimed. |

Test diagram: configured local event → bounded helper → HTTP fixture → delivered; offline/uncertain → durable pending; conflicting ownership → conflict; disabled → no network.

Not in scope: container-agent dispatch, production deployment, replacing local health/review gates. Reuse: common Git binding and preceding plan contracts. Parallel lanes: none; shared-state plans execute sequentially. Routine hardening decisions remain within approved scope.

VERDICT: APPROVED for implementation after incorporated engineering amendments. Required code review remains open.
NO UNRESOLVED DECISIONS

## Implementation Notes

Added a shared lifecycle helper and thin authoring, execution, review, handoff, wrap-up and status callers, with interactive startup onboarding and a disabled shell no-op. Done reporting independently verifies local review/health/work gates, archived tagged content and the actual annotated completion-tag SHA; failed outcomes remain visible as remote blocked notes. Stable repository/plan markers support conservative adoption after local-state loss without duplicate creation or overwriting incompatible manual state; padded local IDs retain their existing tag names. Pre-change characterization was independently reviewed and committed before orchestration changes, and 12 new lifecycle fixtures, 14 transport fixtures, watched CLI flow and full health passed. Independent review findings were fixed and verified; post-completion independent checks remain the orchestrator's next step. No live board mutations or agent dispatch occurred.

**Files changed:**

- `docs/plans/096-paperclip-plan-lifecycle.md`
- `skills/mstack-run/SKILL.md`
- `skills/mstack-run/scripts/paperclip.py`
- `skills/mstack-plan-new/SKILL.md`
- `skills/mstack-plan-multi/SKILL.md`
- `skills/mstack-plan-doctor/SKILL.md`
- `skills/mstack-handoff/SKILL.md`
- `skills/mstack-wrap-up/SKILL.md`
- `skills/mstack-status/SKILL.md`
- `skills/mstack-run/scripts/paperclip_lifecycle.py`
- `skills/mstack-run/scripts/paperclip_lifecycle.sh`
- `skills/mstack-run/scripts/test_paperclip_lifecycle.py`
- `skills/mstack-run/scripts/test_paperclip_lifecycle_characterization.py`

**Commit:** `f3988ff` — feat(paperclip): complete plan 96
