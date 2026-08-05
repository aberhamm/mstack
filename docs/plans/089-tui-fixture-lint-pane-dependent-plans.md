---
id: 089
title: Fixture-as-artifact lint — a pane-dependent plan must attach a real capture
status: in-progress
blocked-by: [088]
goal: review-hardening-rules
allows-migrations: false
needs-review: none
review: adversarial
tui-fixture: n/a  # keyword matches below are this rule's own vocabulary, quoted; this plan scrapes no pane
created: 2026-08-05
---

## Requirements

Rule 3 of `docs/review-hardening-proposal.md`. A plan whose logic keys on
terminal screen content ("when the pane shows X, do Y") is writing a parser
against an undocumented, unversioned external interface. Nobody writes a parser
for a third-party API from memory — they save a real response and code against
it. The capture is that saved response, and the cctrl track record is
unambiguous: every shipped detector bug there (ASCII `>` vs `❯`, an
"Allow command" string matching no real codex modal, and the 2026-08-05 picker
premise) lived in the gap between what an author *remembered* a screen saying
and what it actually says.

The user is the architect running `/mstack-plan-doctor` over a backlog that
contains a pane-scraping plan. Today the doctor validates that plan's structure,
seams, and checks without ever asking whether its detector strings came from a
real screen. After this plan, a pane-dependent plan that ships no dated capture
is flagged before it is ever executed.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] `skills/mstack-run/scripts/fixture-lint.sh lint <plan-ref-or-path>`
      exists, is committed mode `100755`, and emits exactly one verdict line per
      plan whose **first whitespace-delimited token** is one of exactly four
      verdicts: `NOT-APPLICABLE`, `FIXTURE-OK`, `FIXTURE-UNDATED`, or
      `FIXTURE-MISSING`. Anything after that token on the line is human-readable
      detail (a reason, a matched keyword, a path) and is never part of the
      vocabulary — consumers parse token one and ignore the rest, so adding
      detail can never introduce a fifth verdict.
- [ ] A plan is **TUI-dependent** when its Requirements/Design/Tasks prose
      matches the keyword set — `capture-pane`, `send-keys`, `tmux`,
      `pane shows`, `pane content`, `modal`, `picker`, `screen scrape`,
      `screen-scrape` — held as one explicit, tunable list at the top of the
      script. A plan matching none of them is `NOT-APPLICABLE`, exit 0. It still
      prints its one verdict line (the output contract above is unconditional —
      a silent run is indistinguishable from a lint that never executed); what
      it produces no more of is finding rows. This is the overwhelmingly common
      case and must cost nothing beyond that line.
- [ ] A TUI-dependent plan that declares no fixture artifact is
      `FIXTURE-MISSING` and **BLOCKING**: exit `EXIT_TUI_FIXTURE_MISSING` (38).
      "Declares a fixture" means its `**Files expected to change:**` names a
      path under a `fixtures/` directory, or its `## Verification` section
      contains a check that greps a fixture path.
- [ ] A declared fixture that **does not exist** in the working tree is
      `FIXTURE-MISSING` and blocking, with its own message ("declared but
      absent"). The PENDING calibration of plans 046/047 does NOT apply here and
      the difference is the point: those defer on a plan's *output*, and a
      capture is an *input* — evidence the author gathered before writing the
      detector. Rule 3's text is "must attach", present tense. A plan that
      promises to capture the screen later is exactly the plan that will write
      its detector from memory first.
- [ ] A declared fixture that exists but has no provenance is `FIXTURE-UNDATED`
      — reported, never blocking. Provenance lives in a **sidecar**
      `<fixture>.meta` file, not in the capture: Rule 3 requires the dump be
      unedited, and prepending a header edits it. The sidecar carries
      `capture-date: YYYY-MM-DD` and `agent-cli-version: <string>`.
- [ ] The `FIXTURE-MISSING` finding names the matched keyword and quotes the
      matching line, so the architect can dismiss a false positive in seconds
      (a plan that says "modal" about a web dialog is not pane-scraping).
- [ ] A plan may opt out with a frontmatter declaration — `tui-fixture: n/a`
      followed by a `#` comment giving the reason — which the lint honors,
      printing `NOT-APPLICABLE (declared: <reason>)` and exiting 0. The
      declaration must carry a non-empty reason; `tui-fixture: n/a` with no
      reason is NOT honored and the plan is linted normally. This mirrors the
      health gate's block-unless-declared doctrine: the escape hatch is
      explicit, lives in the tracked plan file where review can see it, and is
      never derivable from gitignored local state.
- [ ] This plan (089) carries that declaration and is its own live test case:
      its prose matches several pane keywords because it quotes the rule's own
      vocabulary, and it scrapes no pane.
- [ ] Gated on `rule_enabled tui_fixture` (the helper from 088). When
      `rules.tui_fixture=false` the script prints
      `[mstack] rule tui_fixture: disabled (config)`, emits no findings, and
      exits 0. Setting that one key disables Rule 3 and leaves Rules 1, 4, and 2
      running.
- [ ] `mstack-plan-doctor` gains **Step 3.10** (after Step 3.9, before Step 4)
      running the lint per plan, rendering `FIXTURE` rows in the Step 4 report,
      and adding `FIXTURE-MISSING` to the Step 4b blocking-finding set. Plans
      named in these rows are cited `NNN: Title`.
- [ ] Step 4b's per-modified-plan re-validation list explicitly includes the
      Step 3.10 lint. Without that, a doctor auto-fix that adds pane vocabulary
      to a plan mid-loop is never re-linted, and the Step 4b final-state gate
      would pass on a stale first-pass verdict.
- [ ] The new smoke suite is wired into `skills/mstack-run/hooks/pre-commit`
      (the shipped source), copied to `.githooks/pre-commit`, and added to
      `AGENTS.md`'s smoke-suite list. The hook hardcodes the suite list, so a
      suite that is not added there never runs at commit time — a test nobody
      runs is the same dead-feature class plan 045 documents.
- [ ] `skills/mstack-run/scripts/fixture-lint-smoke.sh` exists, is `100755`, and
      passes. It covers: a non-TUI plan (`NOT-APPLICABLE`, exit 0); a
      pane-scraping plan with no fixture declared (`FIXTURE-MISSING`, exit 38);
      one declaring a fixture that does not exist (`FIXTURE-MISSING`, exit 38,
      "declared but absent"); a declared fixture that exists with a `.meta`
      sidecar (`FIXTURE-OK`, exit 0); the same with no sidecar
      (`FIXTURE-UNDATED`, exit 0); a keyword-matching plan
      carrying `tui-fixture: n/a` with a reason (`NOT-APPLICABLE (declared)`,
      exit 0) and the same without a reason (still `FIXTURE-MISSING`, exit 38);
      and the disabled path.
- [ ] `rule-toggle-smoke.sh` (from 088) gains a case asserting the
      `tui_fixture` key toggles this rule and only this rule.
- [ ] `AGENTS.md` documents the rule, the companion repo-side convention
      (committed pane fixtures carry capture date and agent CLI version, and are
      re-captured on CLI upgrades), and the honest residual that a keyword list
      both over- and under-matches.

## Design

**This lint is deliberately narrow.** It cannot verify that a fixture matches
reality — nothing can, from inside a plan-doctor run. What it can do is refuse
to let a pane-dependent plan proceed with *no* captured evidence at all, which
is the precise gap the cctrl bugs lived in. Claiming more than that would be
the same overreach the proposal warns about.

**Calibration, and where it deliberately departs from 046/047.** Two blocking
cases and one reported one: no fixture declared, and a fixture declared but
absent, both block; missing provenance is reported. The departure is the second
one, and it is deliberate — 046/047's PENDING calibration defers on a plan's
**output** (a test it has not written yet), while a capture is an **input** the
author must already hold. Deferring on it would defeat the rule entirely: "I'll
capture the pane later" is precisely how the detector gets written from memory.
Do not "simplify" this into the PENDING shape by analogy; the analogy is what is
wrong.

**A broader `fixtures/` match than the proposal's `tests/fixtures/`.** The
proposal names `tests/fixtures/`; this lint accepts any path segment
`fixtures/`, because mstack itself keeps no `tests/` root and consumer repos
vary. Stated here so the deviation is a choice on the record, not drift.

**False positives are expected and cheap.** "modal" appears in web plans. The
finding therefore quotes the matching line and names the keyword, so dismissing
one costs a glance. Cheap-to-dismiss is the design constraint that lets the
keyword list stay broad enough to catch real pane work.

**The exemption is a declaration, not a heuristic.** A keyword list will match
prose that discusses pane-scraping without doing any (this plan is the first
example). The escape is an explicit `tui-fixture: n/a  # <reason>` line in the
plan's frontmatter — tracked, visible to review, and requiring a stated reason.
It is deliberately NOT readable from `.mstack/config.json`: that directory is
gitignored, so a declaration there would be per-checkout, invisible to review,
and gone on a fresh clone. Same reasoning, verbatim, as the health gate's
`- none:` declaration rule in `AGENTS.md`.

**Fixture provenance format — a sidecar, because the dump must stay unedited.**
For a capture at `<path>`, provenance lives at `<path>.meta`:

```
capture-date: 2026-08-05
agent-cli-version: claude-code 2.1.4
```

The lint checks only that the sidecar exists and carries both keys, with
`capture-date` matching `YYYY-MM-DD`. Keeping the parse weak is deliberate: a
strict one would reject real captures for cosmetic reasons and earn a bypass.
The sidecar (rather than a header inside the capture) is what makes "unedited
`tmux capture-pane -p` dump" and "carries capture date and CLI version"
simultaneously satisfiable — a header would violate the first to satisfy the
second.

Testing approach: unit-only (shell helper and skill prose; no user-facing
surface).

**Files expected to change:**

- `skills/mstack-run/scripts/fixture-lint.sh`: NEW. `lint <plan>` subcommand,
  the keyword list, the fixture-declaration and provenance checks, exit 38.
- `skills/mstack-run/scripts/fixture-lint-smoke.sh`: NEW. Seven fixture cases.
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: add the new
  suite to the hardcoded smoke list (edit the shipped source first, then copy —
  `.githooks/` is refreshed from it and a `.githooks`-only edit is clobbered).
- `skills/mstack-run/scripts/rule-toggle-smoke.sh`: add the `tui_fixture` case.
- `skills/mstack-run/scripts/lib.sh`: add `EXIT_TUI_FIXTURE_MISSING=38` with a
  documenting comment block (35 is reserved for pending plan 087, 36 is
  `EXIT_HEALTH_INTERNAL`, 37 is plan 088).
- `skills/mstack-plan-doctor/SKILL.md`: add Step 3.10, the `FIXTURE` report
  row, and the Step 4b blocking-set entry.
- `AGENTS.md`: document the rule and the fixture-provenance convention.
- `docs/review-hardening-proposal.md`: mark Rule 3 adopted with its plan id.

**Out of scope:** capturing any actual fixtures (there is no pane-scraping plan
in this backlog to capture for); a doctor check that flags a detector matching
zero live panes for N days (that is cctrl-side and out of this repo); editing
gstack review skills; any change to `review-gate.sh`, `pick-next.sh`,
`health-check.sh`, `result-gate.sh`, or the Step 7a completion sequence.

## Tasks

1. Add `EXIT_TUI_FIXTURE_MISSING=38` to `lib.sh` with its comment block.
2. Write `fixture-lint-smoke.sh` first; confirm it fails before the script
   exists. `chmod +x` and `git update-index --chmod=+x`.
3. Write `fixture-lint.sh`: plan resolution, the `tui-fixture: n/a  # reason`
   frontmatter exemption (reason required), keyword match with the quoted
   matching line, fixture declaration detection over Files-expected-to-change +
   Verification, existence check, `.meta` sidecar read, the `rule_enabled tui_fixture` gate and
   mode line, exit 38.
4. Extend `rule-toggle-smoke.sh` with the `tui_fixture` independence case.
5. Wire `mstack-plan-doctor` Step 3.10, the `FIXTURE` report row, the Step 4b
   blocking-set entry, AND the Step 4b per-modified-plan re-validation list.
6. Add the suite to `skills/mstack-run/hooks/pre-commit`, copy it to
   `.githooks/pre-commit`, and list it in `AGENTS.md`'s smoke battery.
7. Document the rule and the sidecar provenance convention in `AGENTS.md`; mark
   Rule 3 adopted in the proposal doc.
8. Run the full smoke battery, `bash -n`, and `shellcheck` over the changed
   scripts.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/fixture-lint-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/rule-toggle-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash -n skills/mstack-run/scripts/fixture-lint.sh skills/mstack-run/scripts/fixture-lint-smoke.sh skills/mstack-run/scripts/lib.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/fixture-lint.sh skills/mstack-run/scripts/fixture-lint-smoke.sh`
- [cmd] `grep -q "EXIT_TUI_FIXTURE_MISSING=38" skills/mstack-run/scripts/lib.sh`
- [cmd] `grep -q "Step 3.10" skills/mstack-plan-doctor/SKILL.md`
- [assert] `bash skills/mstack-run/scripts/fixture-lint.sh lint 089` output contains NOT-APPLICABLE
  (this plan matches pane keywords because it quotes the rule's own vocabulary,
  and carries the declared exemption — it is the live test of that path)
- [cmd] `grep -q "tui-fixture" AGENTS.md`
