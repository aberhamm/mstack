# Proposal: four review-hardening rules for the plan pipeline

- **Status:** fully adopted. All four rules are implemented — Rule 1 (plan 088),
  Rule 3 (089), Rule 4 (090), Rule 2 (091). Each rule is independently adoptable
  and independently
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

> **ADOPTED — implemented by plan 091**
> (`docs/plans/091-amendment-re-pass-for-review-fixes.md`).
> Mechanism: `skills/mstack-run/scripts/amendment-repass.sh` — `capture` /
> `diff` / `record` / `assert-rechecked` — wired into `mstack-plan-doctor` Step
> 4b (capture at seven enumerated auto-fix sites plus the scoped re-pass), Step
> 5 (an eighth capture taken AROUND the review invocation, since the plan edit
> comes from the review skill and there is no fix site to instrument), Step 4
> (the `AMEND` report row) and Step 6 (`assert-rechecked`, exit 39, refuses
> `ready`). Four things the sketch below did not say and that turned out to
> matter: **the severity signal did not exist** — nothing in the pipeline
> classified an amendment, so `capture` takes severity and trigger as arguments
> under a STRICT 4-arity (a missing argument is a usage error that writes
> nothing; an *unrecognized* severity token stores `p2`, because unknown means
> "needs the re-check"); the re-pass reviewer is given the `diff` output and the
> acceptance criteria and **nothing else**, because a re-pass that re-reads the
> whole plan is a second full review under a different name; the record lives in
> gitignored `.mstack/amendments/` and is therefore **local and
> non-authoritative by construction**, deliberately not frontmatter, because an
> amendment record is not a review verdict; and the whole thing is an
> **honest-path check only** — `assert-rechecked` on a plan with no captures
> exits 0, and there is no write-time hook and no retroactive audit, which is
> the claim plan 039 refused to make about uncommitted work and is refused here
> for the same reason. Disable with
> `config.sh set rules.amendment_repass false`. Doctrine: `AGENTS.md`, "Nobody
> Reviews The Reviewer".

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

> **ADOPTED — implemented by plan 090**
> (`docs/plans/090-premise-attack-brief-for-the-outside-voice.md`).
> Mechanism: prose, in four shipped briefs — the codex brief in
> `skills/mstack-plan-doctor/references/adversarial-audit.md` (premise-attack
> mandate, the explicit "do not sharpen or extend the primary reviewer's
> findings", and an `UNCITED PREMISES (attack these first):` slot fed from Rule
> 1's `UNCITED` lines and omitted entirely when empty), `mstack-plan-doctor`
> Step 3.5 (the no-tension trigger) and Step 5 (the review-invocation mandate
> line), `mstack-plan-multi`'s structural critique (both-clear buys one
> premise-directed re-ask), and `mstack-code-review`'s externally-routed
> reviewer briefs. Two deviations from the sketch below, both deliberate:
> **the "no tension" log line is a single canonical format carrying BOTH
> counts** (codex-clean plans AND primary-validation findings), because the two
> channels merge separately and "codex was silent" is not "everything is
> clean"; and the batch-level trigger is **not** imported into code review,
> whose scope is one diff with no multi-plan aggregation point — it gets the
> `CROSS-MODEL:` row and no extra pass. The trigger counts CONCLUSIVE plans
> only (an `audit-inconclusive` plan is never clean, or a codex timeout would
> manufacture unanimity) and fires at most once per doctor run. Because the
> mechanism is prose, `brief-content-smoke.sh` asserts the directives — and the
> untouched invocation machinery — are still in the shipped files. Disable with
> `config.sh set rules.premise_brief false`, which reverts all four to their
> pre-090 briefs and nothing else. Doctrine: `AGENTS.md`, "Independence of
> Style Is Not Independence of Attention".

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

**Disposition as executed:** Rules 1, 3 and 4 landed in that order (plans 088,
089, 090), then Rule 2 (plan 091), exactly as suggested. Two corrections to the
sketch above, both worth keeping:

- Rule 4 was "a wording change" plus exactly one bounded addition to control
  flow — the no-tension trigger's conditional second pass and its
  report-legality rule. "Zero additional runs in the common case" is true and is
  not the same claim as "no new control flow".
- Rule 2's real cost was not the extra pass. It was that **the amendment
  severity did not exist anywhere in the pipeline** and had to be produced
  before anything could be gated on it — "review fixes above P2" quietly assumed
  a classification nothing was making. Rule 2 trailing until last was right for
  a reason the sketch got only half of.
