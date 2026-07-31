---
id: 082
title: Health trend gets a consumer
status: skipped
blocked-by: [065]
priority:
goal: audit-remediation-roadmap
allows-migrations: false
needs-review: none
created: 2026-07-30
qa: automated
skipped: 2026-07-31
skipped-reason: "backlog optimization: trend dashboard for a metric that currently lies; existing history has plan_id null throughout"
---

## Requirements

`.mstack/health-history.jsonl` is recorded on every gate run and rotated to
100 entries, but nothing acts on it. `status.sh` (lines 247-270) prints the
last-5 raw scores as an arrow chain; `mstack-code-health/SKILL.md` (line 116
onward) asks the LLM to render a table and eyeball "Trend: IMPROVING";
checkpoint counters carry `health_trend` (mstack-checkpoint/SKILL.md line
104) that nothing reads. A slow decline — each plan passing the gate while
the composite bleeds a few tenths — is exactly the state no single run can
see and no component currently reports. The audit's smallest real consumer:
a deterministic decline signal, computed by a script (not LLM eyeballing),
surfaced as a WARNING by one primary skill.

**Acceptance criteria**

- [ ] A new helper `skills/mstack-run/scripts/health-trend.sh` computes a
      deterministic decline signal over the last N (default 5) plan-tagged
      entries (`plan_id != null` in the JSONL, written by health-check.sh's
      history entry) and prints structured output: `TREND:declining` when
      the composite strictly declines across >= 3 consecutive plan-tagged
      entries OR any single category drops >= 2 points from the start to
      the end of the window; else `TREND:stable`; `TREND:insufficient-data`
      when fewer than 3 plan-tagged entries exist. Followed by the window's
      values (`SCORES:9.4 9.1 8.7`, plus the offending `CATEGORY:` line when
      a category drop triggered).
- [ ] `mstack-plan-doctor` (the primary consumer) runs the helper in its
      Step 0 status dashboard and, on `TREND:declining`, surfaces a WARNING
      with the trend values and the suggestion to schedule a cleanup plan.
      Read-only surfacing — no auto plan authoring, no gating, no edits.
- [ ] `mstack-status` shows the same one-line signal beside its existing
      HEALTH TREND section (secondary consumer, also read-only).
- [ ] No jq → the helper announces `TREND_CHECK=skipped-no-jq` and exits 0
      (a degraded run must be legible as degraded, never a silent stable).

## Design

Plan-doctor is the primary consumer because it is the pre-execution
checkpoint where "schedule a cleanup plan" is actionable; status merely
reports. The helper reads the JSONL with jq (`select(.plan_id != null)`),
takes the last N, and does integer-scaled comparison in bash (same
`score * 10` convention as health-check.sh's composite math). Strictly-
declining means every adjacent pair decreases; the per-category rule
compares first-vs-last window entry for each non-null category
(typecheck/lint/test/e2e/deadcode/shell — the e2e field exists after plan
065, and the helper treats an absent category field as null, so pre-065
history lines still parse). Output contract is line-oriented like
health-check.sh so both consumers grep it rather than re-parse JSON. Wire-in
is prose: a short block in plan-doctor's Step 0 dashboard section and in
mstack-status/SKILL.md's health section instructing the agent to run the
helper and render the WARNING verbatim when declining. New script committed
executable. No new smoke suite (the helper is read-only advisory, not a
gate); Verification exercises it against a temp fixture inline.

Testing approach: unit-only

**Files expected to change:**

- `skills/mstack-run/scripts/health-trend.sh`: new helper.
- `skills/mstack-plan-doctor/SKILL.md`: Step 0 dashboard runs the helper,
  renders the WARNING.
- `skills/mstack-status/SKILL.md`: one-line trend signal in the health
  section.

**Out of scope:** auto-authoring cleanup plans; gating or blocking anything
on the trend; changing what health-check.sh records or how status.sh renders
its existing arrow chain; consuming the checkpoint `health_trend` counter
(left as-is); rotating or migrating existing history files.

## Tasks

1. Write `health-trend.sh` (`trend` subcommand, `--window N` optional) with
   the declining/stable/insufficient-data contract and the no-jq
   announcement; source `lib.sh` for `repo_root`/`has_jq`.
2. `chmod +x` and `git update-index --chmod=+x` the new script.
3. Add the plan-doctor Step 0 wiring prose with the exact WARNING format,
   including the trend values and the cleanup-plan suggestion.
4. Add the mstack-status one-line signal prose.
5. Verify against a fixture history file with a known declining sequence.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/health-trend.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/health-trend.sh`
- [assert] `git ls-files -s skills/mstack-run/scripts/health-trend.sh` output contains 100755
- [assert] run from the repo root: `R="$PWD" && d=$(mktemp -d) && cd "$d" && git init -q . && mkdir .mstack && printf '%s\n' '{"ts":"t","plan_id":"1","score":9.4,"test":10}' '{"ts":"t","plan_id":"2","score":9.0,"test":9}' '{"ts":"t","plan_id":"3","score":8.5,"test":7}' > .mstack/health-history.jsonl && bash "$R/skills/mstack-run/scripts/health-trend.sh" trend` output contains TREND:declining
- [assert] run from the repo root: `R="$PWD" && d=$(mktemp -d) && cd "$d" && git init -q . && mkdir .mstack && printf '%s\n' '{"ts":"t","plan_id":"1","score":9.0,"test":10}' '{"ts":"t","plan_id":"2","score":9.0,"test":10}' '{"ts":"t","plan_id":"3","score":9.1,"test":10}' > .mstack/health-history.jsonl && bash "$R/skills/mstack-run/scripts/health-trend.sh" trend` output contains TREND:stable
- [cmd] `grep -q "health-trend.sh" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q "health-trend.sh" skills/mstack-status/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
