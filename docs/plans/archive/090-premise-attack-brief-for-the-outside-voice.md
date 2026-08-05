---
id: 090
title: Brief the outside voice to attack premises; "no tension" is a trigger, not a clearance
status: done
blocked-by: [088, 089]
goal: review-hardening-rules
allows-migrations: false
needs-review: none
review: adversarial
created: 2026-08-05
completed: 2026-08-05
reviewed: false
qa: automated
---

## Requirements

Rule 4 of `docs/review-hardening-proposal.md`. The cross-model channels in this
pipeline currently get a brief that is a *sharper version of the primary
review's job*: falsify the plan's cited claims, find structural decomposition
problems, review the diff for correctness. What they are never told to do is
attack the plan's **premises** — and that is the gap the cctrl 051–053 batch
fell through. Its own review report says it: "CROSS-MODEL: No tension — Codex
sharpened two review findings rather than disputing them." Two models sharing
the plan's framing produce independence of *style*, not independence of
*attention*. The third-model audit that did catch both P1s was not smarter; it
was briefed adversarially. The differentiator is the mandate, and the mandate is
free.

The user is the architect whose backlog goes through plan-doctor's Step 3.5
codex audit, plan-multi's structural critique, and mstack-code-review's
cross-model reviewer. After this plan, each of those gets a premise-attack
mandate, and a unanimous "all clear" across a multi-plan batch is logged as a
smell that costs one more pass instead of being cited as confirmation.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] The codex brief in
      `skills/mstack-plan-doctor/references/adversarial-audit.md` instructs the
      auditor to attack premises, in this priority order: (a) the plan's uncited
      factual claims — fed in from `premise-lint.sh`'s `UNCITED` lines (plan
      088), (b) every "should / presumably / by construction / obviously"
      sentence, (c) any premise whose failure would invalidate a whole
      acceptance criterion rather than a detail. It states explicitly: **do not
      sharpen or extend the primary reviewer's findings** — that work is already
      done and repeating it is what produced the false clearance.
- [ ] The same brief keeps the existing `file:line`-anchored `FINDING:` output
      schema, the GENUINE-vs-FORWARD-DEPENDENCY classifier, the fault-tolerance
      rules, and the 300s timeout unchanged. This plan changes the mandate, not
      the machinery.
- [ ] `premise-lint.sh`'s `UNCITED` lines for the plan under audit are passed
      into the codex prompt as a named section (`UNCITED PREMISES (attack these
      first):`). When Rule 1 is disabled or the lint produced nothing, the
      section is omitted entirely — never sent empty, never sent as "none found"
      (which would read as a clearance the lint never gave).
- [ ] `mstack-plan-doctor` Step 3.5 gains the **no-tension trigger**: when the
      audit returns zero findings across **two or more** plans in one run, the
      doctor logs the canonical line defined in the next criterion (there is
      exactly one format, and it always carries both counts) and runs exactly
      ONE additional codex pass, scoped
      to premises only, over the plans that came back clean. The trigger fires
      at most once per doctor run (it is a smell check, not a loop), and its
      result is reported as `AUDIT [PREMISE-PASS]` rows.
- [ ] **"No tension" names the audit channel only, and the log line says so.**
      The Step 3 validators' findings are merged separately (`SKILL.md:856`) and
      may be non-empty while codex returns nothing — which is a *different*
      state from "everything is clean" and must not be collapsed into it. The
      log line therefore carries both counts, and this is the ONLY format —
      the trigger, the waiver, and the report row all use it:
      `CROSS-MODEL: no tension — codex clean on N/N conclusive plans, primary
      validation raised M findings — <running one premise-directed pass | premise
      pass WAIVED (<reason>)>`. The trigger keys on the codex count; the primary
      count is printed so the reader is never told two channels agreed when only
      one was silent.
- [ ] **An `audit-inconclusive` plan is not a clean plan.** Only plans whose
      audit was CONCLUSIVE and returned zero findings count toward the trigger's
      N, and an inconclusive plan is never included in the premise pass's scope.
      Today inconclusive contributes no findings
      (`references/adversarial-audit.md:160-163`), so counting it as clean would
      let a codex timeout manufacture the very unanimity this trigger exists to
      distrust.
- [ ] The no-tension trigger can be waived explicitly rather than silently: if
      the architect declines the extra pass, the canonical line above closes
      with its `premise pass WAIVED (<reason>)` arm instead of the running arm.
      A "no tension" line with neither a premise-pass result nor a recorded
      waiver is not a legal report state.
- [ ] `skills/mstack-plan-multi/references/structural-critique.md`'s Synthesize
      section states the same convention for the decomposition critique: "both
      clear" across a multi-plan breakdown is a smell, not a confirmation, and
      is followed by one premise-directed re-ask or an explicit note that it was
      skipped.
- [ ] `skills/mstack-code-review/SKILL.md`'s externally-routed reviewer (the
      standard reviewer when routed through codex/gemini, and the adversarial
      reviewer in adversarial mode) gets the premise-attack framing adapted to
      code — attack what the diff *assumes* about the code around it, not what
      it does.
- [ ] The code-review `CROSS-MODEL:` report row states agreement **between
      reviewers on one diff**, NOT across plans. Code review's scope is a single
      diff (`SKILL.md:69-74`) and it has no multi-plan aggregation point, so
      importing the batch-level trigger there would be a category error. The
      row's convention: in adversarial or thorough mode, when the external
      reviewer returns zero findings AND the Claude reviewer's findings are all
      dimensions the external one also examined, print `CROSS-MODEL: no tension
      (external reviewer added nothing)` — a note the human reads as weak
      evidence, never as a second confirmation. Standard mode with one reviewer
      prints `CROSS-MODEL: n/a (single reviewer)`. No extra pass is triggered
      here; the batch-level trigger stays in plan-doctor where batches exist.
- [ ] `mstack-plan-doctor` Step 5 passes the premise-attack mandate into the
      `/plan-eng-review` invocation context: "attack the plan's premises before
      its details; a premise whose failure invalidates a whole AC outranks any
      number of detail findings." The gstack skill file itself is NOT edited —
      it lives outside this repo. Note Step 5 today says only "Pass the plan
      file path as context" (`SKILL.md:1288-1294`) — there is no context
      template to extend. Plan 088 creates that block; this plan appends one
      line to it. If 088's block is absent for any reason, this plan creates it
      rather than assuming it.
- [ ] All of the above are gated on `rule_enabled premise_brief` (the helper
      from 088). With `rules.premise_brief=false`, every touched step
      states it is using the pre-090 brief and prints
      `[mstack] rule premise_brief: disabled (config)`. Rules 1, 3, and 2 are
      unaffected by that key.
- [ ] `rule-toggle-smoke.sh` gains a `premise_brief` independence case, and a
      new `brief-content-smoke.sh` asserts the shipped brief text actually
      carries the premise-attack directives and the no-tension convention in all
      four touched files — the guard against a prose rule being silently lost to
      a later edit.
- [ ] `AGENTS.md` records the doctrine in one paragraph: independence of style
      is not independence of attention; a unanimous cross-model clearance is
      evidence about the brief, not about the plan.

## Design

**Mostly a mandate change — with one deliberate, bounded addition to control
flow.** The briefs, the report rows, and the eng-review context line are pure
wording. The no-tension trigger is not: Step 3.5 today runs one codex audit per
plan and merges the results, with no conditional second pass and no waiver state
(`SKILL.md:904-941`). This plan adds exactly one conditional pass and one
report-legality rule. Say so plainly rather than filing it under "just a
re-brief" — the proposal's "zero additional runs in the common case" is true and
is not the same claim as "no new control flow".

What stays untouched, deliberately: the codex invocation itself (sandbox flags,
`mktemp` template, `< /dev/null`, `2>"$TMPERR"`, the 300s timeout), the
`FINDING:` schema, the GENUINE/FORWARD-DEPENDENCY classifier, and the
fault-tolerance rules. Rewriting any of those would put the cheap part of the
proposal at the risk level of the expensive part.

**Why the no-tension trigger is bounded to one extra pass.** The smell is
"unanimity across a batch", which is a per-run property, so the response is a
per-run pass. A per-plan trigger would fire on every clean single-plan doctor
run and turn a smell check into a tax; an unbounded trigger would loop. One
pass, once, over the plans that came back clean.

**The trigger's cost profile is the reason it is acceptable.** In the common
case (findings exist) it costs nothing. It fires exactly when the pipeline is
about to tell the architect "two models agree, ship it" — the moment that
produced two P1s in the batch this proposal came from.

**Feeding Rule 1's output into Rule 4 is a one-directional dependency.** Rule 4
reads `premise-lint.sh`'s output when it is there and omits the section when it
is not. Disabling Rule 1 degrades Rule 4's targeting; it does not break it. That
is why 090 is blocked-by 088 but the two toggles stay independent.

**Honest residual, to be stated in `AGENTS.md` and not overclaimed:** a brief
cannot make a model independent. It changes what the model is pointed at, which
is the demonstrated differentiator in this one case (a third model with an
adversarial mandate found what two models with a confirmatory mandate missed).
It is not a guarantee, and the no-tension trigger is a smell heuristic, not a
detector.

Testing approach: unit-only (skill prose plus a content-assertion smoke suite;
no user-facing surface).

**Files expected to change:**

- `skills/mstack-plan-doctor/references/adversarial-audit.md`: the premise-attack
  brief inside the literal codex command, the `UNCITED PREMISES` injection
  slot, and a rubric section describing the mandate.
- `skills/mstack-plan-doctor/SKILL.md`: Step 3.5 gains the no-tension trigger,
  the waiver form, and the `AUDIT [PREMISE-PASS]` report row; Step 5's
  eng-review invocation context gains the premise-attack mandate line.
- `skills/mstack-plan-multi/references/structural-critique.md`: Synthesize
  section gains the "both clear is a smell" convention.
- `skills/mstack-code-review/SKILL.md`: the externally-routed reviewer briefs
  and the `CROSS-MODEL:` report row.
- `skills/mstack-run/scripts/brief-content-smoke.sh`: NEW. Asserts the four
  files above carry the required directives.
- `skills/mstack-run/scripts/rule-toggle-smoke.sh`: add the `premise_brief` case.
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: add
  `brief-content-smoke.sh` to the hardcoded suite list (shipped source first,
  then copy — a `.githooks`-only edit is clobbered on the next `mstack-init`).
- `AGENTS.md`: the doctrine paragraph and the honest residual.
- `docs/review-hardening-proposal.md`: mark Rule 4 adopted with its plan id.

**Out of scope:** editing the gstack `plan-eng-review` / `plan-design-review` /
`plan-ceo-review` skills; adding a third model or any additional review round
(the proposal explicitly disclaims both); changing the codex invocation
mechanics, sandbox flags, timeout, or fault-tolerance rules; changing the
finding schema or the GENUINE/FORWARD-DEPENDENCY classifier; the amendment
re-pass (plan 091).

## Tasks

1. Rewrite the codex brief in `references/adversarial-audit.md` with the
   premise-attack mandate and the priority order, plus the `UNCITED PREMISES`
   injection slot and its omit-when-empty rule. Leave the command mechanics,
   schema, classifier, and fault tolerance untouched.
2. Add the no-tension trigger, the waiver form, and the `AUDIT [PREMISE-PASS]`
   row to plan-doctor Step 3.5; add the premise mandate to Step 5's eng-review
   context.
3. Add the "both clear is a smell" convention to plan-multi's structural
   critique Synthesize section.
4. Add the premise framing to mstack-code-review's externally-routed reviewer
   briefs and the `CROSS-MODEL:` row to its Step 6 report.
5. Gate each of the four on `rule_enabled premise_brief`, each printing its mode
   line and naming the pre-090 fallback brief.
6. Write `brief-content-smoke.sh` asserting the directives are present in all
   four files; extend `rule-toggle-smoke.sh` with the `premise_brief` case.
   `chmod +x` and `git update-index --chmod=+x` the new script.
7. Add `brief-content-smoke.sh` to `skills/mstack-run/hooks/pre-commit`, copy to
   `.githooks/pre-commit`, and list it in `AGENTS.md`'s smoke battery.
8. Write the doctrine paragraph in `AGENTS.md`; mark Rule 4 adopted in the
   proposal doc.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/brief-content-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/rule-toggle-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash -n skills/mstack-run/scripts/brief-content-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/brief-content-smoke.sh`
- [cmd] `grep -qi "do not sharpen or extend" skills/mstack-plan-doctor/references/adversarial-audit.md`
- [cmd] `grep -q "UNCITED PREMISES" skills/mstack-plan-doctor/references/adversarial-audit.md`
- [cmd] `grep -qi "no tension" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -qi "no tension" skills/mstack-plan-multi/references/structural-critique.md`
- [cmd] `grep -q "CROSS-MODEL" skills/mstack-code-review/SKILL.md`
- [cmd] `grep -q "premise_brief" skills/mstack-plan-doctor/SKILL.md`

## Implementation Notes

Rule 4 ships as a premise-attack mandate in four briefs — plan-doctor's codex
audit (with the `UNCITED PREMISES` slot fed from Rule 1's lint and omitted
entirely when empty), plan-doctor Step 5's review-invocation context, plan-multi's
structural critique, and code-review's externally-routed reviewers — each gated
on `rule_enabled premise_brief` with its mode line and the pre-090 brief kept
verbatim as a named fallback.

Step 3.5 carries the one bounded control-flow addition: a once-per-run
no-tension trigger over CONCLUSIVE-and-clean plans only (an audit-inconclusive
plan never counts as clean and never enters the pass's scope, so a codex timeout
cannot manufacture unanimity), with a single canonical log line carrying both the
codex-clean count and the primary-validation finding count, closing on either the
running arm or an explicit WAIVED arm.

Scope correction held: code review reviews ONE diff and has no multi-plan
aggregation point, so its `CROSS-MODEL:` row reports reviewer-vs-reviewer
agreement only and triggers no extra pass.

Because Rule 4's mechanism is prose, `brief-content-smoke.sh` (44 assertions)
guards the shipped directives against silent deletion by a later edit, and also
asserts the invocation machinery this plan was NOT to touch is still intact. Its
ability to fail was demonstrated, not assumed: deleting the do-not-sharpen
directive and mangling the single-reviewer row produced exit 1 naming each
missing directive; both were restored and the suite returned to 44/44.

**Files changed:**

- `skills/mstack-plan-doctor/references/adversarial-audit.md` (modified)
- `skills/mstack-plan-doctor/SKILL.md` (modified)
- `skills/mstack-plan-multi/references/structural-critique.md` (modified)
- `skills/mstack-code-review/SKILL.md` (modified)
- `skills/mstack-run/scripts/rule-toggle-smoke.sh` (modified)
- `skills/mstack-run/hooks/pre-commit` (modified)
- `.githooks/pre-commit` (modified)
- `AGENTS.md` (modified)
- `docs/review-hardening-proposal.md` (modified)
- `skills/mstack-run/scripts/brief-content-smoke.sh` (created)

**Commit:** `da53ac8` — `feat(plan 090): brief the outside voice to attack premises`
