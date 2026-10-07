---
id: 94
title: Add reliable human-session Paperclip reporting
status: in-progress
blocked-by: [93]
goal: paperclip-native-integration
allows-migrations: false
needs-review: none
review-required: eng,code
created: 2026-10-07
reviews:
  - type=eng verdict=approved date=2026-10-07 by=mstack-review
---

## Plain-English Summary

Progress reporting must not create duplicate tasks or replay an old status over a newer result after an outage. This provides the shared reporting mechanism used by onboarding and execution.

**What changes in the code:** A native helper handles authenticated requests and ordered reporting events, adapting the working standalone prototype without personal defaults.

## Requirements

- [ ] Read the selected official board credential using the prototype credential-key contract documented by `API` in `/Users/matthew/.config/skillshare/skills/mstack-paperclip/scripts/paperclip.py`; never log credentials or include them in event storage.
- [ ] Use bounded connection/request timeouts and record visible pending delivery instead of failing local execution on outages.
- [ ] Persist per-plan ordered events under common Git integration state, with stable event IDs across retries; an uncertain mutation must be reconciled before resend.
- [ ] Reject conflicting human/agent ownership and active execution; assign external work to the authenticated human only and never call wakeup or agent-assignment APIs.
- [ ] Fetch complete issue records before changing managed fields; preserve unrelated descriptions, human notes, and manually changed states.
- [ ] Superseded queued statuses cannot overwrite newer committed outcomes; deduplicate comments via stable request IDs and verify supported server behavior rather than assuming task creation is idempotent.
- [ ] Disabled mode exits before importing optional runtime dependencies, discovering credentials or contacting the network.

## Design

Testing approach: E2E

Adapt ~/.config/skillshare/skills/mstack-paperclip/scripts/paperclip.py as a reference, not a runtime dependency. Introduce a shared emit/reconcile/status CLI contract with JSON inputs containing repository_id, plan_id, event_id, sequence, outcome, session/worktree metadata and sanitized notes. Serializing an outbox is a local lock, not a cross-machine claim guarantee. Re-read server state before replay; surface ownership conflicts for reconciliation. Characterize create/comment idempotency against an isolated HTTP fixture and the pinned pilot API before relying on it. No unbounded retries or daemon.

**Transport contract:** `paperclip.py emit --repo PATH --json FILE`, `reconcile --repo PATH --limit N`, and `status --repo PATH` consume plan093 configuration. Emit JSON carries schema_version=1, repository_id, plan_id, event_id, sequence, outcome, metadata and notes; output JSON carries delivery (`delivered|pending|conflict|disabled`), event_id and sanitized diagnostic. Store ordered events and mappings under the common Git integration directory; credential values never enter these files. Total invocation deadline 30 seconds, at most 10 queued events per reconcile.

**Credential boundary:** Reject authenticated redirects before forwarding Authorization, including same-origin redirects; normalize api_base and reject userinfo, query and fragment without echoing submitted URL text. Treat 401 as authentication-expired, 403 as authorization conflict, timeouts/network errors as offline/pending and uncertain mutations as pending reconciliation. Embed a stable event marker in created issue descriptions and comment bodies, and search complete paginated records for an exact marker match. Do not assume commentClientRequestId or create idempotency is guaranteed by API documentation. Stable comment/request markers must be confirmed by exact full-record readback before resend; unresolved uncertainty never authorizes blind recreation.

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip.py`: native transport/event delivery helper
- `skills/mstack-run/scripts/paperclip.sh`: optional no-op-capable entrypoint
- `skills/mstack-run/scripts/test_paperclip_transport.py`: mock HTTP and uncertain-delivery fixtures

**Out of scope:** container-agent dispatch, production code deployment, replacing local review/health gates, automatic Git branches, and secrets in tracked files.

## Tasks

1. Adopt and parameterize transport from the prototype.
2. Define event schema and atomic local event storage.
3. Implement delivery and uncertain-outcome reconciliation.
4. Test conflict, ordering, duplicate delivery and timeout handling.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_transport.py -v
- [manual] Check the configured mode and actual observed behavior; do not claim remote delivery from a queued event.

<!-- mstack:seam
produced:
- kind: file; name: skills/mstack-run/scripts/paperclip.py; file: skills/mstack-run/scripts/paperclip.py
- kind: file; name: skills/mstack-run/scripts/paperclip.sh; file: skills/mstack-run/scripts/paperclip.sh
assumed:
- from: 093; kind: file; name: skills/mstack-run/scripts/paperclip_config.py; file: skills/mstack-run/scripts/paperclip_config.py
-->

## GSTACK REVIEW REPORT

| Review | Runs | Status | Findings |
|---|---:|---|---|
| Architecture | 1 | PASS after amendments | Reject authenticated redirects; explicit event markers/readback forbid blind duplicate mutation. |
| Code quality | 1 | PASS | Shared CLI contracts pinned; no duplicate transports or credential storage. |
| Tests | 1 | PASS for implementation | Timeout/outage, stale-sequence, uncertain-create, redirects, ownership, pagination and disabled-path HTTP fixtures. New code tests have not run yet. |
| Performance | 1 | PASS | Bounded requests/queues; no startup network for disabled modes. |
| Outside voice | 0 | UNAVAILABLE | Configured Codex CLI rejects gpt-6.1-sol with ChatGPT account; no outside clearance claimed. |

Test diagram: configured local event → bounded helper → HTTP fixture → delivered; offline/uncertain → durable pending; conflicting ownership → conflict; disabled → no network.

Not in scope: container-agent dispatch, production deployment, replacing local health/review gates. Reuse: common Git binding and preceding plan contracts. Parallel lanes: none; shared-state plans execute sequentially. Routine hardening decisions remain within approved scope.

VERDICT: APPROVED for implementation after incorporated engineering amendments. Required code review remains open.
NO UNRESOLVED DECISIONS
