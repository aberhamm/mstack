# Proposal: four review-hardening rules for the plan pipeline

- **Status:** partially adopted. Rules 1 and 3 are implemented (plans 088 and
  089); Rules 2 and 4 remain proposals. Each rule is independently adoptable and
  independently
  disableable via its own `rules.<key>` toggle — see `AGENTS.md`, "The
  `rules.*` toggle namespace".
- **Origin:** the cctrl 051-053 batch (2026-08-05). Three plans cleared eng
  review plus a Codex outside-voice pass (18 findings folded in, verdict
  "ENG CLEARED, no unresolved decisions") while still carrying two P1 defects —
  both in plan 053's pane-inference layer, both fatal to its first real run.
  A third-model adversarial audit caught them
  (`~/dev/cctrl/docs/reviews/2026-08-05-fable-architecture-audit.md`, findings
  F1/F2). This proposal is the process residue: what would have caught them
  *inside* the pipeline, generalized.
- **Non-goal:** more review volume. The pipeline already produces plenty of
  findings (18 on this batch, all real). The failure mode was *depth on the
  wrong axis*: both reviewers verified the plan's cited claims and its internal
  coherence, and neither tested its two uncited factual premises against code.
  These rules aim review attention, they do not add rounds.

---

## Rule 1 — Citation-or-finding: uncited factual premises are findings by default

> **ADOPTED — implemented by plan 088**
> (`docs/plans/088-citation-or-finding-lint-for-uncited-premises.md`).
> Mechanism: `skills/mstack-run/scripts/premise-lint.sh`, run per plan by
> `mstack-plan-doctor` Step 3.9; `CITED-UNRESOLVED` blocks in the script
> (exit 37) and `UNCITED` blocks at the Step 4b gate unless resolved. The
> reviewer half of the rule is wired as the citation checklist line in the
> Step 5 review-invocation context block. Doctrine and the honest residual
> (the UNCITED detector is a word list; it both over- and under-matches) live
> in `AGENTS.md`, "An Uncited Factual Premise Is a Finding". Disable with
> `config.sh set rules.citation_or_finding false`.

**The rule.** Every acceptance criterion that *depends on a fact about existing
code* must cite the function it depends on (function names, not line numbers —
cctrl plan 035's convention). Review then has two jobs: verify cited premises
against the cited code, and treat any load-bearing premise *without* a citation
as an automatic finding — not "probably fine", a finding, resolved only by
adding the citation and verifying it.

**Why this catches the class.** Both P1s were exactly the two uncited premises
in the batch. "The picker is a modal, so `_session_rich_state` should report
`blocked-dialog`" cited nothing; had it been forced to cite
`_session_pane_has_dialog`, the signature mismatch was a ten-second grep.
Meanwhile every *cited* claim in the same plans (line refs, JSON key counts,
measured timings) had been verified by the reviews — the pipeline already does
this half well. The rule closes the asymmetry: today, decorating a claim with a
citation *attracts* verification while omitting one *exempts* it, which is
backwards.

**Cost.** Small at plan-author time (the author knows which function they're
assuming things about). At review time it *redirects* effort rather than adding
it.

**Wiring, if adopted:** mstack-plan-doctor gains a lint ("AC asserts behavior
of existing code with no `function_name` citation"); the eng-review skill's
checklist gains "every cited premise verified, every uncited premise filed."

---

## Rule 2 — Amendment re-pass: review fixes above P2 get one adversarial re-check

**The rule.** When a review *changes* a plan (folds in a fix, rewrites an AC),
any amendment whose subject is P2-or-above gets one focused adversarial pass
before the plan is stamped cleared: a reviewer (fresh context, ideally the
outside voice) attacks only the amended text, with the brief "assume this fix
introduced a new defect; find it."

**Why this catches the class.** The codex-readiness P1 was not in the original
plan — it was *created by the eng review's own fix*. The review correctly
replaced a too-loose negative readiness form with an allow-list, and the
allow-list is unsatisfiable for codex sessions. Nobody reviews the reviewer:
amendments folded in during review currently ship with zero scrutiny, which
means the highest-churn text in the pipeline (the fixes) gets the least
attention. This is the standard regression problem — fixes need review too —
appearing at the plan layer.

**Cost.** One bounded pass per cleared plan, scoped to diffs only. On the 053
batch this would have been ~15 minutes against three amended sections.

**Wiring, if adopted:** the review-report template gains an "amendments
re-checked: yes/no + by whom" row; "CLEARED" requires it for any P2+ amendment.

---

## Rule 3 — Fixture-as-artifact for TUI-dependent plans

> **ADOPTED — implemented by plan 089**
> (`docs/plans/089-tui-fixture-lint-pane-dependent-plans.md`).
> Mechanism: `skills/mstack-run/scripts/fixture-lint.sh`, run per plan by
> `mstack-plan-doctor` Step 3.10. One verdict line per plan from a closed set of
> four: `FIXTURE-MISSING` blocks in the script (exit 38) both when no capture is
> declared and when a declared one is absent; `FIXTURE-UNDATED` is reported;
> `NOT-APPLICABLE` is the common case. Three deviations from the wiring sketched
> below, all deliberate: any `fixtures/` path segment counts (not only
> `tests/fixtures/`, since mstack keeps no `tests/` root and consumer repos
> vary); provenance lives in a `<fixture>.meta` SIDECAR rather than a header
> inside the capture — a header would edit the dump this rule requires be
> unedited; and **the keyword list below is implemented in two tiers**, because
> the flat version was measured against the live backlog and fired on 9 of 41
> plans with a 100% false-positive rate. STRONG keywords (`capture-pane`,
> `send-keys`, `tmux`, `pane shows`, `pane content`, `screen scrape`,
> `screen-scrape`) name the mechanism of reading a screen and fire alone; WEAK
> keywords (`modal`, `picker`) name a screen artifact and fire only alongside a
> strong one, since "picker" in mstack means `pick-next.sh`. Real pane work
> loses no coverage: a plan that scrapes a pane must say how it reads the pane.
> Opt out per plan with `tui-fixture: n/a  # <reason>` (the reason is
> required); disable the rule with `config.sh set rules.tui_fixture false`.
> Doctrine: `AGENTS.md`, "A Pane-Dependent Plan Must Attach a Real Capture".

**The rule.** Any plan whose logic keys on terminal screen content ("when the
pane shows X, do Y") must attach a dated, unedited `tmux capture-pane -p` dump
of X as a plan artifact, and the plan's detector claims must be demonstrated
against that capture (a one-line grep in the Verification section suffices).
Hand-typed or from-memory pane text does not satisfy the rule. Companion
convention on the repo side: committed pane fixtures carry capture date and
agent CLI version, and are re-captured on CLI upgrades.

**Why this catches the class.** Pane-scraping is an integration against an
undocumented, unversioned external interface. Nobody writes a parser for a
third-party API from memory — they save a real response and code against it;
the capture is that saved response. The track record in cctrl is unambiguous:
every shipped detector bug (ASCII `>` vs `❯`, "Allow command" matching no real
codex modal, and now the picker premise) lived in the gap between what an
author *remembered* a screen saying and what it says. The real picker string
sat in the homelab restore manifest all along; the rule makes that check
mechanical at plan time instead of forensic at audit time.

**Cost.** One command per screen state, once per plan. The friction of
producing a capture for a hard-to-reach state is itself information — the
detector will face the same state in production.

**Wiring, if adopted:** plan-doctor flags plans matching pane/TUI keywords
(`capture-pane`, `send-keys`, "pane shows", "modal", "picker") that have no
`tests/fixtures/` artifact in their file list.

---

## Rule 4 — Brief the outside voice to attack premises; treat "no tension" as a trigger, not a clearance

**The rule.** The cross-model outside-voice review gets a different brief from
the primary review: do not sharpen or extend the primary reviewer's findings —
attack the plan's *premises*, prioritizing (a) uncited factual claims (Rule 1's
list), (b) "should/presumably/by construction" sentences, and (c) any premise
whose failure would invalidate a whole AC rather than a detail. And when the
cross-model comparison comes back "no tension" across a multi-plan batch, that
is logged as a smell that triggers one more premise-directed pass — not cited
as mutual confirmation.

**Why this catches the class.** The 051-053 batch's own review reports say it:
"CROSS-MODEL: No tension — Codex sharpened two review findings rather than
disputing them." Two models sharing the plan's framing produce independence of
*style*, not independence of *attention*; both evaluated whether the picker
logic was internally coherent, and neither asked whether its factual premise
held. The third-model audit that did catch the P1s was not smarter — it was
*briefed adversarially* ("your value is disagreement; hunt for what both prior
reviewers missed"). The differentiator is the mandate, and the mandate is free.

**Cost.** Zero additional runs in the common case; a re-brief of an existing
step. The "no tension → one more pass" trigger adds a pass only when the smell
fires.

**Wiring, if adopted:** the codex-review invocation template in the review
skill gets the adversarial premise-attack brief; the review-report template's
CROSS-MODEL row gains the convention that "no tension" must be accompanied by
either a premise-pass result or an explicit waiver.

---

## What this proposal deliberately does not claim

- That the pipeline failed wholesale. It folded 18 real findings into three
  plans and materially improved all of them; two of the P1-class defects in the
  *original* drafts (the already-live contradiction, the loose readiness form)
  were caught by the existing process.
- That a third model should review everything. The catch here came from the
  brief, not the model count; Rule 4 moves the brief into the standing process
  so the second model can do the job of the third.
- That these rules guarantee catching the next one. They target the two
  demonstrated escape routes (uncited premises; unreviewed amendments) and the
  one demonstrated recurring bug class (fixture-reality gaps in TUI code).

## Suggested disposition

Adopt Rules 1 and 3 first (cheap, mechanical, lintable by plan-doctor). Rule 4
is a wording change to the codex-review brief. Rule 2 costs the most per plan
and can trail until Rules 1+4 have run on a real batch.
