---
id: 080
title: derive code-review depth from risk signals instead of a never-set field
status: pending
blocked-by: [069]
priority:
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

`mstack-code-review` defines `review: adversarial|thorough` modes
(`skills/mstack-code-review/SKILL.md:5-9` description, `:28-35` mode
definitions, `:109-143` the adversarial pipeline) chosen ONLY via plan
frontmatter — and a grep across all 43 archived + 42 pending plans shows the
field has never been set once (`grep -rn '^review:' docs/plans/` → zero
matches), including on the enforcement-layer plans 034-039 that are precisely
the "high-stakes" class adversarial mode names ("auth, payments, data
migrations", SKILL.md:30-31). The choosing moment (authoring) has no prompt
and no heuristic, so the depth dial exists but is never turned.

**Acceptance criteria**

- [ ] `mstack-code-review` Step 2 auto-escalates standard → adversarial when
      any deterministic risk signal fires: diff > 400 lines (from the
      `git diff --stat` its Step 1 already computes, SKILL.md:76-78); OR
      touched paths intersect the enforcement-sensitive list; OR plan
      frontmatter `allows-migrations: true`; OR `review-required` contains
      `eng`.
- [ ] Explicit frontmatter `review:` always wins in BOTH directions: a plan
      stamped `review: thorough` is not downgraded, and a plan explicitly
      stamped `review: standard` is not escalated. Auto-escalation applies
      only when the field is absent.
- [ ] The review output (Step 6 report and the `REVIEW COMPLETE` block)
      announces the escalation and names which signal(s) fired.
- [ ] `mstack-plan-multi` authoring (Step 3b "Review assignments",
      `skills/mstack-plan-multi/SKILL.md:143`) stamps `review: adversarial`
      into plans matching the same signals at authoring time (path/migration/
      eng-review signals; the diff-size signal is execution-only).
- [ ] The signal list is defined in exactly ONE place; plan-multi and
      code-review both cite it rather than restating it.
- [ ] Default sensitive-path list ships in code; `.mstack/config.json` can
      EXTEND it (never replace/shrink it) via a documented key.

## Design

Single source of truth: a **"Risk signals" section in
`skills/mstack-code-review/SKILL.md`** (code-review is the consumer that
enforces at execution time; plan-multi references it by section name at
authoring time). No new script — the signals are four cheap checks the LLM
already has the inputs for (diff stat, `git diff --name-only`, plan
frontmatter), and prose in one named section keeps them greppable. Default
sensitive-path list: `skills/mstack-run/scripts/`, `skills/mstack-run/hooks/`,
`.githooks/`, `bin/`, `setup` — the same enforcement surface AGENTS.md's
pre-commit smoke trigger names. Config extension: a
`review.sensitive_paths_extra` array in `.mstack/config.json` (read alongside
the existing `review.provider` key, SKILL.md:67); absent key = default list,
never fewer. (Precision note: AGENTS.md's pre-commit trigger greps
`skills/**/*.sh` broadly; this list deliberately narrows that to
`skills/mstack-run/scripts/` and adds `.githooks/` — an adaptation of the
enforcement surface, not a byte-identical copy of the hook's pattern.)

**Base-rate consequence — intended, state it in the shipped section too:**
`review-required: eng` currently marks 22 of 42 pending plans (the
enforcement-critical class), so the eng signal alone makes adversarial the
EFFECTIVE DEFAULT for the majority of gated work in this repo. That is the
intent — eng-gated plans are precisely the high-stakes class the adversarial
mode's own prose names — and the cost is bounded: one extra blind reviewer
pass per review, no thorough-mode fan-out. The Risk signals section must
state this consequence explicitly so a future session does not read the
escalation rate as a bug.

Escalation semantics: standard → adversarial only. Signals never touch a plan
that has an explicit `review:` value (SKILL.md:84-85's "check the plan's
frontmatter" step gains the escalation branch when the field is unset).
`thorough` remains reachable only by explicit frontmatter.

Testing approach: unit-only.

**Files expected to change:**

- `skills/mstack-code-review/SKILL.md`: new "Risk signals" section; Step 2
  escalation branch; Step 6 report line naming fired signals.
- `skills/mstack-plan-multi/SKILL.md`: Step 3b review assignments also stamp
  `review: adversarial` for signal-matching plans, citing the code-review
  Risk signals section.
- `skills/mstack-run/plan-template.md`: one-line comment on the `# review:`
  line (line 21) noting auto-escalation exists and explicit values win.
- `AGENTS.md`: document `review.sensitive_paths_extra`.

**Out of scope:** changing adversarial/thorough pipeline internals; a new
shell helper or scoring machinery; retro-stamping `review:` onto archived
plans; auto-escalating TO `thorough`; `mstack-plan-doctor` scoring changes.

## Tasks

1. Add the "Risk signals" section to `mstack-code-review/SKILL.md` with the
   four signals, the default sensitive-path list, and the
   `review.sensitive_paths_extra` extension rule.
2. Wire Step 2: when frontmatter `review:` is absent, evaluate signals and
   escalate to adversarial; record which fired.
3. Add the fired-signal line to the Step 6 report and the
   `REVIEW COMPLETE` integration block.
4. Update `mstack-plan-multi` Step 3b to stamp `review: adversarial` at
   authoring for path/migration/eng signals, referencing the canonical
   section.
5. Update `plan-template.md` comment and `AGENTS.md` config documentation.

## Verification

Checks:

- [assert] `grep -c 'Risk signals' skills/mstack-code-review/SKILL.md` → >= 1
- [cmd] `grep -q 'Risk signals' skills/mstack-plan-multi/SKILL.md`
- [cmd] `grep -q 'sensitive_paths_extra' AGENTS.md`
- [cmd] `grep -q 'sensitive_paths_extra' skills/mstack-code-review/SKILL.md`
- [assert] `grep -c 'skills/mstack-run/scripts/' skills/mstack-code-review/SKILL.md` → >= 1 (default list present)
- [cmd] `grep -q 'review: adversarial' skills/mstack-plan-multi/SKILL.md`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [manual] confirm an explicitly-stamped `review: standard` plan is not escalated
