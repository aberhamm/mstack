---
id: 95
title: Offer Paperclip onboarding and reconnection
status: done
blocked-by: [93, 94]
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

Users should connect the dashboard once rather than set identifiers by hand in every session. Onboarding offers a connection when needed and remembers users who choose to work without it.

**What changes in the code:** Init and configuration skills guide connection, verify the selected company/project, and save settings through the shared helper.

## Requirements

- [ ] Expose /mstack-config paperclip connect, status, reconnect and disable, with explicit states and actionable diagnostics.
- [ ] Offer connect or continue-without once on eligible interactive initialization/startup; persist decline and do not repeatedly prompt. Deterministic bootstrap and headless execution never wait for human input.
- [ ] Reuse a valid official board login; if absent/expired launch official CLI login and wait for its user approval without bypassing authentication.
- [ ] Let the user select URL, company and a remote project returned by the authenticated project-list API; create a new remote project only when the user chooses creation. Verify identifiers before saving enabled binding.
- [ ] Worktree initialization reuses the repository binding and preserves health, review, hooks and unrelated settings.
- [ ] Reconnect repairs credentials without silently replacing project bindings; offline instances are distinguishable from expired credentials.

## Design

Testing approach: E2E

Keep user interaction in skills; helpers return structured choices and state. Profile endpoint discovery can suggest the current official CLI context but never silently enable external writes merely because credentials exist. Offer missing setup once per repository, including repositories initialized before this feature. Actual authentication approval remains the official browser gate. No onboarding in worker subagents or deterministic bootstrap. Require a supported URL scheme and explain localhost/tailnet connectivity only when relevant.

**Onboarding interface:** Consume plan093 status/configure/disable and plan094 authenticated transport. Helpers return choices and observed state; skill prose owns human interaction and official CLI login approval. Verify selected project.companyId equals selected company before enabling. Failed/aborted reconnect preserves the previous enabled binding. Existing-repository interactive startup callers are wired in plan096; deterministic init only reports eligibility.

**Files expected to change:**

- `skills/mstack-init/SKILL.md`: interactive onboarding offer
- `skills/mstack-config/SKILL.md`: connection commands and decisions
- `skills/mstack-run/scripts/init.sh`: noninteractive detection only
- `skills/mstack-run/scripts/test_paperclip_onboarding.py`: scripted interaction/HTTP fixtures

**Out of scope:** container-agent dispatch, production code deployment, replacing local review/health gates, automatic Git branches, and secrets in tracked files.

## Tasks

1. Add configure/status/reconnect helper operations.
2. Wire interactive setup decisions into init/config skills.
3. Persist declines and suppress repeated/headless prompts.
4. Test existing-login, expired-login, unavailable-server and reused-worktree flows.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_onboarding.py -v
- [manual] Check the configured mode and actual observed behavior; do not claim remote delivery from a queued event.

<!-- mstack:seam
produced:
assumed:
- from: 093; kind: file; name: skills/mstack-run/scripts/paperclip_config.py; file: skills/mstack-run/scripts/paperclip_config.py
- from: 094; kind: file; name: skills/mstack-run/scripts/paperclip.py; file: skills/mstack-run/scripts/paperclip.py
-->

## GSTACK REVIEW REPORT

| Review | Runs | Status | Findings |
|---|---:|---|---|
| Architecture | 1 | PASS after amendments | Company/project membership validated; aborted reconnect preserves binding; interactive skills own official approval. |
| Code quality | 1 | PASS | Shared CLI contracts pinned; no duplicate transports or credential storage. |
| Tests | 1 | PASS for implementation | One-time offer/decline, headless suppression, existing login, expired login, offline and worktree fixtures. New code tests have not run yet. |
| Performance | 1 | PASS | Bounded requests/queues; no startup network for disabled modes. |
| Outside voice | 0 | UNAVAILABLE | Configured Codex CLI rejects gpt-6.1-sol with ChatGPT account; no outside clearance claimed. |

Test diagram: configured local event → bounded helper → HTTP fixture → delivered; offline/uncertain → durable pending; conflicting ownership → conflict; disabled → no network.

Not in scope: container-agent dispatch, production deployment, replacing local health/review gates. Reuse: common Git binding and preceding plan contracts. Parallel lanes: none; shared-state plans execute sequentially. Routine hardening decisions remain within approved scope.

VERDICT: APPROVED for implementation after incorporated engineering amendments. Required code review remains open.
NO UNRESOLVED DECISIONS

## Implementation Notes

Added structured onboarding helpers and actionable connect/status/reconnect/disable skill flows with explicit profile, company and project selection. Interactive initialization remembers its offer and declined setup; deterministic bootstrap reports eligibility without Python, network calls or prompts. Existing login is reused, official approval remains in the interactive skill, and failed reconnect or shared-profile retargeting preserves existing bindings. Nine onboarding fixtures and the full health gate passed; the independent review finding was fixed and verified. No live board mutations, installations or agent dispatch occurred.

**Files changed:**

- `docs/plans/095-paperclip-onboarding.md`
- `skills/mstack-config/SKILL.md`
- `skills/mstack-init/SKILL.md`
- `skills/mstack-run/scripts/config.sh`
- `skills/mstack-run/scripts/init.sh`
- `skills/mstack-run/scripts/paperclip_onboarding.py`
- `skills/mstack-run/scripts/test_paperclip_onboarding.py`

**Commit:** `c6ad174` — feat(paperclip): complete plan 95
