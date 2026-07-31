---
id: 073
title: Notification config and stuck-state escalation
status: pending
blocked-by: []
priority: 31
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-30
qa: automated
reviews:
  - type=eng verdict=approved date=2026-07-30 by=mstack-plan-doctor
---

## Requirements

The only notification in the framework fires on SUCCESS: mstack-run's
"Completion notification" (mstack-run/SKILL.md lines 1238-1245) sends
"backlog clear" if a notify tool happens to be in allowed-tools, and the MCP
tool itself ships as a commented-out example (lines 35-36). Every stuck
state — plan failed (Step 7b), plan blocked (Step 3b/7a), a Step 1 BAIL, an
`[mstack] ANOMALY:` detection, an open review gate, mstack-investigate
exhausting its strike budget — is silent. For an autonomous loop the
operator walks away from, that is inverted: success needs no interrupt, a
stuck loop needs one. The audit ranked this the single biggest autonomy
lever. Make notification configurable and fire it on stuck states, with the
same non-blocking posture the current success path has: silently skip when
unconfigured, never crash the loop on notify failure.

**Acceptance criteria**

- [ ] `.mstack/config.json` gains a `notify` section: `notify.tool` (string;
      an MCP tool name like `mcp__telegram-claude__send_message`, or a shell
      command) and `notify.on` (comma-separated subset of
      `failed,blocked,anomaly,bail,clear`; default all five). `config.sh`
      validates `notify.on` values on `set` and `DEFAULT_CONFIG` carries the
      section; `skills/mstack-config/SKILL.md` documents the schema.
- [ ] mstack-run fires a notification on each terminal/stuck outcome —
      failed, blocked, bail, anomaly — and keeps the existing clear
      notification, each gated by its `notify.on` membership.
- [ ] mstack-investigate's exhaustion path (3 categories exhausted → STOP,
      SKILL.md lines 141-143) fires a `failed`-class notification.
- [ ] Every message carries: the plan as `NNN: Title` (plan_label, per the
      Plan Citation Convention), the reason, and the exact ready-to-paste
      remediation command the skill already composes in its block/fail
      messages (e.g. the named review skill to run, or the mstack-investigate
      invocation).
- [ ] Unconfigured (`notify.tool` empty/absent) → today's behavior, silent
      skip. A failing notify tool never fails, blocks, or retries the loop.
- [ ] Agent-neutral per AGENTS.md compatibility rules: prose instructs the
      agent to invoke the configured tool; no hard MCP dependency, and shell
      commands work identically under Codex.

## Design

Shape decision: a single `notify.tool` string, discriminated by prefix — a
value starting with `mcp__` is an MCP tool the agent calls with the message
as its text argument; anything else is a shell command run as
`<command> "<message>"` via Bash. This keeps config flat (a 2-level path,
inside `json_get`'s working range even jq-less) and needs no `notify.mode`
enum. `notify.on` is read once at Step 1 config load alongside the existing
reads. The firing sites are prose additions at the points where each outcome
message is already composed: Step 7b (failed), the Step 7a/3b blocked paths,
the Step 1 bail branch ("If a bail check failed", line 1259), the anomaly
line (line 1197 family), and the existing Step 8 clear block (lines
1238-1245) rewritten to use `notify.tool` + `notify.on clear` instead of
"if a tool is in allowed-tools". Each site reuses the message it already
prints — plan_label + reason + remediation command — prefixed
`[mstack] <event>:`. The commented allowed-tools example (lines 35-36) stays
as the hint for Claude users to allow their MCP tool; the shell-command form
needs no allowed-tools change. mstack-investigate adds one prose paragraph
at its STOP branch. Notify failure handling is explicit in each block:
"if the call errors, note it in the progress line and continue — never
retry, never abort."

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/config.sh`: `notify` in `DEFAULT_CONFIG`;
  `notify.on` validation in `cmd_set`.
- `skills/mstack-config/SKILL.md`: schema docs for `notify.tool`/`notify.on`.
- `skills/mstack-run/SKILL.md`: firing prose at the five outcome sites.
- `skills/mstack-investigate/SKILL.md`: exhaustion-path notification.

**Out of scope:** adding any MCP server or dependency; retry/queueing/
digest logic; notifying on per-step progress or review-gate state changes
beyond the five events; changing what the block/fail messages say; plan 066's
`json_get` internals (2-level reads work with jq present; without jq the
read fails and `config.sh get` exits nonzero, which lands on this plan's
sanctioned unconfigured/silent-skip path — never a crash).

## Tasks

1. Add the `notify` section to `DEFAULT_CONFIG` and `cmd_set` validation
   (`notify.on` must be a comma-list drawn from the five events;
   `notify.tool` free-form).
2. Document the schema and both tool shapes in mstack-config/SKILL.md.
3. Rewrite mstack-run's clear-notification block to the config-driven form;
   add firing prose to the failed/blocked/bail/anomaly sites with message =
   plan_label + reason + remediation command, and the never-crash rule.
4. Add the exhaustion notification to mstack-investigate's STOP branch.
5. Run syntax/shellcheck and the smoke suites; spot-check `config.sh get`.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/config.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/config.sh`
- [assert] `bash skills/mstack-run/scripts/config.sh get notify.on` output contains failed,blocked,anomaly,bail,clear
- [cmd] `grep -q "notify.tool" skills/mstack-config/SKILL.md`
- [assert] `grep -c "notify" skills/mstack-run/SKILL.md` output is >= 5
- [cmd] `grep -q "notify" skills/mstack-investigate/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [manual] `config.sh set notify.on bogus` dies with a validation error
