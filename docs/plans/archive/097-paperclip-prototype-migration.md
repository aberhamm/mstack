---
id: 97
title: Adopt existing Paperclip tracking and install native integration
status: done
blocked-by: [93, 94, 95, 96]
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

The working prototype already contains project records that must not be duplicated during migration. This replaces the separate tracking setup with native mstack behavior and validates both machines.

**What changes in the code:** Migration verifies existing mappings, transfers ownership of source-status reporting, and installs the native skills while leaving service hosting in homelab.

## Requirements

- [ ] Adopt the 11 project bindings and 384 imported records described in `/Users/matthew/dev/homelab/.worktrees/paperclip-pilot/ma2-apps/paperclip/sources.json` through a dry-run mapping report; ambiguous or missing records are retained and surfaced, never deleted or recreated blindly.
- [ ] Recognize `paperclip-source` hash markers emitted by `/Users/matthew/dev/homelab/.worktrees/paperclip-pilot/ma2-apps/paperclip/sync_sources.py` using original repository/name/source identities; map unique native plans by stable IDs while keeping TODO-only and colliding historical plan-ID records independently visible by exact source identity, with collision diagnostics and no lifecycle mapping.
- [ ] Transfer bounded source-status block ownership once; redirect or retire the homelab sync only after verified parity so two writers cannot race.
- [ ] Move the shared skill/helper source into mstack; setup/Skillshare installs or replaces the prototype without overwriting unrelated skills and preserves rollback copies.
- [ ] Verify separate credentials/profile bindings on Studio and MacBook without copying secrets into sources; integration works from primary and detached worktrees.
- [ ] Run one disposable tracking-task lifecycle from authenticated external sessions and confirm zero container-agent wakeups; test missing config, declined and unreachable-server behavior.
- [ ] Document onboarding, default use, manual recovery and rollback; deployment, databases and backups remain owned by homelab.

## Design

Testing approach: E2E

Use /Users/matthew/dev/homelab/.worktrees/paperclip-pilot/ma2-apps/paperclip/sources.json and sync_sources.py as rollout inputs, not product defaults or permanent dependencies. The actual Paperclip endpoint/company IDs are discovered/configured, never hardcoded for all users. Source-sync description reconciliation and lifecycle state reporting have explicit separate managed fields during migration. Default migration is read-only; apply verified mappings under this approved scope, preserve unknown records and credentials, and maintain a tested restore path for the prototype. Prototype backup retention is necessary until native reporting parity is verified. Exact unique remote source markers permit independent source adoption even when historical local plan IDs collide; collision records retain their issue and source-status block, expose diagnostics, and receive no native lifecycle mapping. Missing or ambiguous remote markers still abort apply. Studio owns source-status refresh; MacBook uses explicit mappings-only adoption with zero remote PATCH, retaining missing local plans as independent source-only records with diagnostics. No unrelated repository pulls, source snapshot transfers or ID rewrites are performed.

**Adoption/installer contract:** Add `paperclip_lifecycle.py adopt --repo PATH --sources FILE` for read-only reports and explicit `--apply` for verified mappings only. Fixture-test the prototype ordinary-directory case that setup currently skips: save a rollback copy before an explicit managed replacement; never overwrite unrelated skill directories. Abort apply on ambiguous mappings. Source-status writer transfer is operator-visible and paired with parity/rollback checks.

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip_lifecycle.py`: native adoption command

- `skills/mstack-paperclip/SKILL.md`: native compatibility entrypoint
- `setup`: safe skill installation/migration
- `README.md`: optional integration and onboarding guidance
- `skills/mstack-run/scripts/test_paperclip_migration.py`: adoption and installer fixtures
- `docs/paperclip-migration.md`: operator rollout and ownership handoff

**Out of scope:** container-agent dispatch, production code deployment, replacing local review/health gates, automatic Git branches, and secrets in tracked files.

## Tasks

1. Add dry-run adoption and ambiguity diagnostics.
2. Implement safe installer/compatibility migration and rollback.
3. Document and transfer source-status writer ownership.
4. Configure verified current projects on both machines and run the disposable end-to-end smoke.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_migration.py -v
- [manual] Check the configured mode and actual observed behavior; do not claim remote delivery from a queued event.

<!-- mstack:seam
produced:
- kind: file; name: docs/paperclip-migration.md; file: docs/paperclip-migration.md
- kind: file; name: skills/mstack-paperclip/SKILL.md; file: skills/mstack-paperclip/SKILL.md
assumed:
- from: 096; kind: file; name: skills/mstack-run/scripts/paperclip_lifecycle.py; file: skills/mstack-run/scripts/paperclip_lifecycle.py
-->

## GSTACK REVIEW REPORT

| Review | Runs | Status | Findings |
|---|---:|---|---|
| Architecture | 1 | PASS after amendments | Explicit dry-run/adopt mapping and backed-up prototype migration; never recreate ambiguous records. |
| Code quality | 1 | PASS | Shared CLI contracts pinned; no duplicate transports or credential storage. |
| Tests | 1 | PASS for implementation | Prototype real-directory installer replacement/restore; historical marker and writer parity; two-machine external-session smoke. New code tests have not run yet. |
| Performance | 1 | PASS | Bounded requests/queues; no startup network for disabled modes. |
| Outside voice | 0 | UNAVAILABLE | Configured Codex CLI rejects gpt-6.1-sol with ChatGPT account; no outside clearance claimed. |

Test diagram: configured local event → bounded helper → HTTP fixture → delivered; offline/uncertain → durable pending; conflicting ownership → conflict; disabled → no network.

Not in scope: container-agent dispatch, production deployment, replacing local health/review gates. Reuse: common Git binding and preceding plan contracts. Parallel lanes: none; shared-state plans execute sequentially. Routine hardening decisions remain within approved scope.

VERDICT: APPROVED for implementation after incorporated engineering amendments. Required code review remains open.
NO UNRESOLVED DECISIONS

## Implementation Notes

Implemented and installed reviewed native tracking pin42347a3964d5b25c55c75c18dc73a0761ae83df2 on both Macs with tested prototype restore and retained installer-chain backups; actual Codex/Claude skill resolution and separate host authentication were verified. Studio adopted11 projects/384 records (279 native plans,9 colliding source-only plans,96 TODOs), proved zero-refresh bounded source-block parity using an operator-derived mstack task-worktree path, and transferred the canonical legacy writer guard; MacBook shares stable repository IDs and adopted384 records with783 actual GET requests and zero remote mutations (117 native plans,165 missing and6 colliding source-only plans,96 TODOs). Existing MAT-388 and MAT-389 completed through authenticated CLI boundaries with actual committed archive/annotated tag and human-owned done readbacks, mapped-outage pending/reconcile, disabled/declined checks, common-Git identity and unchanged heartbeat-run IDs proving zero new agent wakeups; full health passed71 Python tests plus17 retained shell suites and shell lint, with actual independent review recorded. Live schema-rejected smoke updates required explicit disposable-only manual recovery after full marker/readback verification, missing MacBook sources remain independently visible until future source updates, and skill-path resolution does not claim Cowork UI execution; homelab guard commit fb8e9bb and canonical ownership commit dd3ed4c preserve hosting responsibility and canonical manifest bytes.

**Files changed:**

- `README.md`
- `bin/mstack-update-check`
- `docs/plans/097-paperclip-prototype-migration.md`
- `setup`
- `skills/mstack-run/scripts/paperclip.py`
- `skills/mstack-run/scripts/paperclip_lifecycle.py`
- `skills/mstack-run/scripts/test_paperclip_transport.py`
- `docs/paperclip-migration.md`
- `skills/mstack-paperclip/SKILL.md`
- `skills/mstack-run/scripts/paperclip_adoption.py`
- `skills/mstack-run/scripts/paperclip_install.py`
- `skills/mstack-run/scripts/test_paperclip_migration.py`

**Commit:** `267518e` — feat(paperclip): complete plan 97
