---
id: 045
title: wrap-up must distinguish a scaffold plan from an authored one before staying silent
status: pending
blocked-by: []
priority:
goal:
allows-migrations: false
needs-review: none
review-required: eng
created: 2026-07-26
qa: automated
---

## Requirements

`mstack-wrap-up`'s **Git hygiene before the ending** step excludes any
untracked/modified `docs/plans/NNN-*.md` that carries no recorded `reviews:`
entry, classifying it "deliberate, never actionable" and saying nothing. Two
materially different states are indistinguishable under that test, because both
have no `reviews:` entry:

- **(a) a fresh scaffold** from `mstack-plan-new` — instructional placeholders
  only, nothing at risk, correctly silent;
- **(b) a fully-authored, not-yet-reviewed plan** — an entire session's research
  output living in a single untracked file.

The rule was derived from `review-gate.sh assert-committed`'s docstring, which
says an unapproved plan is "exempt, may sit dirty". That is **permission granted
to the completion gate not to block**. Wrap-up read it as **instruction not to
mention**, converting a non-blocking rule into silence.
Permission-not-to-block and instruction-not-to-ask are different things, and
conflating them is the defect.

**Real incident (2026-07-26, `~/dev/django-celery-scraper`):** a 419-line
fully-authored plan, `docs/plans/075-encrypt-social-account-credentials.md`,
representing a whole session of research, was untracked at close. Wrap-up said
nothing. The human caught it. As of this writing that repo still has two more
untracked authored plans (`074-…`, 64 lines; `076-…`, 87 lines) that today's
rule would also silence — this is reproducing, not a one-off.

**Fail direction must invert.** When the discriminator cannot tell, the plan is
treated as **authored (ask)**, never scaffold (silent). Asking costs one button;
silence costs a session's only artifact. Today's default fails the expensive way.

**Acceptance criteria**

- [ ] `review-gate.sh plan-authored <plan>` exists: exit `0` = authored (surface
      it), exit `EXIT_PLAN_SCAFFOLD` (32) = pristine scaffold (silent). It prints
      a one-line verdict plus reason to stdout.
- [ ] The sentinel set is **derived from `plan-template.md` at runtime**, not
      hardcoded — there is no second copy of the template's instructional prose
      anywhere in the tree.
- [ ] Any failure mode — template unreadable, fewer than 3 sentinels extracted,
      plan unreadable, unresolvable ref — yields **authored**, not scaffold.
      Only the exact exit code 32 buys silence; every other exit (including a
      crash, exit 1/2) means ask.
- [ ] `mstack-wrap-up/SKILL.md` classifies uncommitted plan files in **three**
      tiers — scaffold (silent, unchanged) / authored-unreviewed (SURFACED in the
      git-hygiene question) / approved-and-dirty (a real finding, unchanged) —
      and calls the helper rather than judging by LLM.
- [ ] The verdict stays **non-blocking** in all three tiers. This changes what is
      asked, never what is gated.
- [ ] `wrapup-scan.sh` is unchanged: its contract still promises it knows nothing
      about frontmatter, and it stays strictly path-only.
- [ ] `mstack-wrap-up/SKILL.md`'s git-hygiene examples render `unpushed` entries
      truthfully: `ahead=<n>` renders as "N commits unpushed on <branch>",
      `upstream=none` renders as "<branch> has no upstream" — they are different
      facts and must not share one sentence.
- [ ] `review-gate-smoke.sh` covers all three tiers plus the fail-open-to-ask
      paths, and passes.
- [ ] `bash -n` and `shellcheck` pass on every touched script.

## Design

### Where the logic goes

`review-gate.sh` already owns plan-file introspection (`_plan_relpath`,
`_read_target`, `resolve_plan_ref`, `fm_get`, `review_entries`), so the
discriminator goes there as a new subcommand. `wrapup-scan.sh` is untouched:
its pinned output contract states it reports paths and knows nothing about
frontmatter, and that separation is why the main agent — not the scan subagent —
does classification.

### Reuse investigation (done; recorded so it is not re-litigated)

`mstack-plan-doctor/SKILL.md` does carry this idea twice — the Clarity rubric
(`0: Template placeholders or empty sections`, ~line 426) and the acceptance
criteria check (`- [ ] items, not placeholders`, ~line 763). **Both are LLM
rubric prose evaluated by a scoring subagent; neither is code.** There is
nothing deterministic to extract or share. What *would* have been duplication is
a hardcoded sentinel list — a second copy of the template's instructional prose,
free to drift. This plan avoids that by deriving sentinels from
`plan-template.md` itself, which makes the canonical template the single source
of truth for what "still a scaffold" means. plan-doctor's rubric prose is left
alone: it scores plan *quality* on a 0-10 scale for a human/LLM reader, a
different job from a binary shell gate, and rewriting it to call the helper
would be scope creep with no defect behind it.

### The discriminator

`cmd_plan_authored <plan>`:

1. Resolve the template: `$SCRIPT_DIR/../plan-template.md` (co-located with the
   script in every install layout, so no four-path loop is needed). Unreadable →
   **authored**, reason `template-unavailable`.
2. Extract sentinels from the template **body only** (everything after the
   closing `---` of frontmatter). Keep a line if, after trimming, it is:
   non-empty; not a heading (`#`); not an HTML-comment delimiter or fence
   (`<!--`, `-->`, `---`); not a bare list/step stub (`- [ ] ...`, `1. ...`,
   `- ...`); and at least 24 characters long. Headings and stubs are excluded
   precisely because **every** plan has them — a sentinel that matches authored
   plans is not a sentinel.
3. **Vacuous-truth guard:** fewer than 3 sentinels extracted → **authored**,
   reason `sentinels-unavailable`. Without this, an empty extraction makes
   "all sentinels present" vacuously true and silences everything — the same
   bug class in miniature.
4. Compare against the target plan's trimmed lines. **Scaffold iff EVERY
   extracted sentinel is still present.** Any single sentinel replaced means a
   human or agent wrote something, so: ask.

The all-or-nothing threshold is deliberate. A percentage threshold has to pick a
number, and every number below 100% creates a band where a half-authored plan —
a session's work in progress — is silently discarded. The known cost of 100% is
that a plan scaffolded from an *older* template version no longer matches
today's sentinels and is classified authored: one extra button, which is the
cheap failure direction by design.

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: add `EXIT_PLAN_SCAFFOLD=32` with a comment
  stating the inverted polarity (exit 0 = authored; only 32 = silent). Next free
  code after `EXIT_HEALTH_NO_TOOLS=31`; collides with nothing.
- `skills/mstack-run/scripts/review-gate.sh`: add `_template_sentinels` and
  `cmd_plan_authored`; wire `plan-authored` into `main()`, `usage()`, and the
  header subcommand docs.
- `skills/mstack-wrap-up/SKILL.md`: rewrite the "An uncommitted plan file is
  deliberate, not dirt" section into the three-tier rule (retitled), name the
  permission-vs-instruction category error explicitly so it is not
  re-derived, add the helper invocation, update the git-hygiene "actionable
  uncommitted work" definition, and fix the `unpushed` example wording in all
  three renderings.
- `skills/mstack-run/scripts/review-gate-smoke.sh`: add the tier coverage.
- `AGENTS.md`: pin the doctrine — permission-not-to-block ≠ instruction-not-to-ask,
  and the deliberately inverted `plan-authored` polarity, so a later agent does
  not "fix" exit 0 into meaning scaffold.
- `skills/mstack-run/scripts/fixtures/review-gate/authored-plan.md`: new fixture,
  a plausible authored plan carrying zero template sentinels.

The pristine-scaffold case is built **at test time by copying the live
`plan-template.md`** into a temp dir rather than as a checked-in fixture: a
static copy would drift from the template silently, and the copy is exactly what
`mstack-plan-new` produces.

**Out of scope:** changing `wrapup-scan.sh` (contract is correct as written);
changing `assert-committed`'s semantics or any completion/review gate (this plan
touches what is *asked*, never what is *gated*); rewriting plan-doctor's scoring
rubric to call the helper; adding a plan-quality score to wrap-up; touching
review state on any plan; pushing.

## Tasks

1. Add `EXIT_PLAN_SCAFFOLD=32` to `lib.sh` with the polarity comment.
2. Implement `_template_sentinels` + `cmd_plan_authored` in `review-gate.sh`;
   wire into `usage()`, `main()`, and the header docs.
3. Add the `authored-plan.md` fixture.
4. Extend `review-gate-smoke.sh`: pristine template copy → 32; authored fixture
   → 0; one-sentinel-replaced scaffold → 0; missing template → 0; unresolvable
   ref → not-32.
5. Rewrite the wrap-up classification section into three tiers, with the
   helper call and the fail-direction rule.
6. Update the git-hygiene "actionable uncommitted work" definition to include
   authored-unreviewed plans, and fix all three `unpushed` renderings.
7. Run `bash -n`, `shellcheck`, and both smoke scripts.

## Verification

Checks:

- [cmd] `bash -n skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/lib.sh skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/review-gate-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/wrapup-scan-smoke.sh` (proves the scan
  contract is untouched)
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh` (the helper is
  useless if consumers cannot resolve it — this shipped 100644 and the
  discriminator never ran)
- [assert] `git ls-files -s skills/mstack-run/scripts/review-gate.sh` starts
  with `100755`
- [assert] a pristine copy of `plan-template.md` run through
  `review-gate.sh plan-authored` exits 32 and prints `scaffold`
- [assert] `review-gate.sh plan-authored docs/plans/045-*.md` exits 0 and prints
  `authored` (this plan is itself the authored-case witness)
- [assert] `grep -c 'What user-visible problem does this solve' skills/mstack-wrap-up/SKILL.md` is 0
  (no hardcoded second copy of the template prose)
- [manual] the git-hygiene block in `mstack-wrap-up/SKILL.md` renders
  `upstream=none` and `ahead=<n>` as distinct sentences
