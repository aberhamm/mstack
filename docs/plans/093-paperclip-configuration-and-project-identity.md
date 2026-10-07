---
id: 93
title: Configure optional Paperclip tracking and stable project identity
status: in-progress
blocked-by: []
goal: paperclip-native-integration
allows-migrations: false
needs-review: none
review-required: eng,code
created: 2026-10-07
reviews:
  - type=eng verdict=approved date=2026-10-07 by=mstack-review
---

## Plain-English Summary

Connecting Paperclip should survive changing worktrees without changing how local checks behave. This adds a clear connection state and a consistent project binding, while keeping credentials private.

**What changes in the code:** A structured settings helper resolves integration settings separately from the existing checkout-local health configuration.

## Requirements

- [ ] Disabled or unconfigured integration performs zero network calls and needs no Paperclip CLI or Python for ordinary mstack execution.
- [ ] Represent unconfigured, declined, disabled, enabled, offline, and authentication-expired separately; transient failures do not rewrite enabled settings.
- [ ] Resolve a repository binding through its common Git directory across primary and detached/linked worktrees; preserve `repo_root()` in `skills/mstack-run/scripts/lib.sh` and the checkout-local `CONFIG_FILE` in `skills/mstack-run/scripts/config.sh`.
- [ ] Store only mode, profile reference, company/project identifiers and stable repository identity in repository binding state; keep URL and credential-store reference in a user profile. Never store a token in repository configuration.
- [ ] A second machine can use its own authenticated profile and explicitly reuse the same remote project; renamed remotes cannot silently create a new project.
- [ ] Validate closed integration schemas, preserve unrelated settings, atomically replace JSON under a bounded local lock, and reject malformed settings with a visible diagnostic.

## Design

Testing approach: E2E

Use ~/.config/mstack/paperclip.json for named user profiles and the repository common Git directory/mstack-paperclip/binding.json for machine-local shared binding state. A profile holds api_base and auth_file reference; a binding holds mode, profile, company_id, project_id and repository_id. Declined/disabled is persisted even without a profile. Treat Git common directories as local identity only, never as identifiers shared between machines. Resolve existing explicit IDs before looking up remote names; ambiguous remote/project matches require onboarding. Do not reuse config.sh string interpolation for URLs or identifiers.

**Shared CLI contract (produced here):** `python3 paperclip_config.py status --repo PATH` prints one JSON object with `mode`, `state`, `repository_id`, `profile`, `company_id`, `project_id`, `diagnostic`; `configure --repo PATH --json FILE` and `disable --repo PATH` atomically validate/write the same binding. Configuration errors return nonzero with sanitized diagnostics; status is read-only and performs no network requests. Profile JSON schema version 1 contains a named `profiles` map with `api_base` and `auth_file`; binding schema version 1 contains `mode`, `profile`, `company_id`, `project_id`, `repository_id`. Observed offline/auth-expired states are runtime observations, not stored modes. Native transport plan094 and onboarding plan095 consume this interface.

**Files expected to change:**

- `skills/mstack-run/scripts/paperclip_config.py`: new structured profile/binding resolver and writer
- `skills/mstack-run/scripts/config.sh`: integration setting entrypoints without changing existing defaults
- `skills/mstack-run/scripts/test_paperclip_config.py`: identity/state/config-preservation fixtures

**Out of scope:** container-agent dispatch, production code deployment, replacing local review/health gates, automatic Git branches, and secrets in tracked files.

## Tasks

1. Define and test the state/schema contract.
2. Implement common-Git-directory binding resolution and profile lookup.
3. Implement validated atomic configuration writes and state diagnostics.
4. Add config compatibility and no-network-disabled fixtures.

**Disabled runtime characterization:** Test the optional shell path with python3, jq and node hidden from PATH; ordinary pre-existing config.sh operations must remain unchanged. No shell caller may invoke this Python resolver in unconfigured/disabled/declined execution.

**Health test reachability:** During implementation configure this task worktree’s gitignored health.commands.test to run all native Python tests and the existing shell smoke suites; never replace or hide the existing checks. Include a missing-test regression so an omitted test module fails instead of producing a green zero-test result.

## Verification

- [cmd] python3 -m unittest skills/mstack-run/scripts/test_paperclip_config.py -v
- [manual] Check the configured mode and actual observed behavior; do not claim remote delivery from a queued event.

<!-- mstack:seam
produced:
- kind: file; name: skills/mstack-run/scripts/paperclip_config.py; file: skills/mstack-run/scripts/paperclip_config.py
assumed:
-->

## GSTACK REVIEW REPORT

| Review | Runs | Status | Findings |
|---|---:|---|---|
| Architecture | 1 | PASS | Common Git binding stays separate from checkout-local health CONFIG_FILE (`config.sh:9`, `lib.sh:242`). |
| Code quality | 1 | PASS | Closed schemas and atomic bounded-lock writes; credential values never enter bindings. |
| Tests | 1 | PASS for implementation | Require no-runtime PATH fixture, detached identity/config preservation and missing-test failure. Native tests are future verification, not run yet. |
| Performance | 1 | PASS | Disabled zero-network/no-Python path and bounded lock. |
| Outside voice | 0 | UNAVAILABLE | Configured Codex CLI rejects gpt-6.1-sol for ChatGPT account; no external clearance claimed. |

Test diagram: absent/declined/disabled → shell no-op without Python; enabled → common-Git binding → user profile; malformed JSON → sanitized diagnostic; detached checkout → same binding + separate health config.

Not in scope: agent dispatch, deployment, replacement of local health/review gates. Reuse: config.sh, lib.sh and shell smoke suites. Parallel lanes: none within shared binding work. Routine decisions: explicit structured config operations and private machine-local binding.

VERDICT: APPROVED for implementation. Required code review remains open until implementation is reviewed.
NO UNRESOLVED DECISIONS
