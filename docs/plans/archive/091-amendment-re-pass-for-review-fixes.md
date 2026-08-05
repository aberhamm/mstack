---
id: 091
title: Amendment re-pass — a review's own fix gets one adversarial re-check
status: done
blocked-by: [088, 089, 090]
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

Rule 2 of `docs/review-hardening-proposal.md`. The highest-churn text in this
pipeline is the text reviews *write*, and it is the only text nothing reviews.
One of the two P1s in the cctrl 051–053 batch was not in the original plan — the
eng review created it, correctly replacing a too-loose negative readiness form
with an allow-list that turns out to be unsatisfiable for codex sessions. The
fix was right in direction and wrong in fact, and it shipped with zero scrutiny
because amendments folded in during review are stamped cleared along with
everything else.

mstack has the same hole in a different shape. Plan-doctor's Step 4b already
re-validates a plan the doctor edited — structurally. It re-runs frontmatter
checks, scoring, seam diffs, and the audit. What it never does is look at the
**amendment itself** with the one question that catches this class: *assume this
fix introduced a new defect; find it.*

The user is the architect whose plan just had a GENUINE audit finding auto-fixed,
or a `changes-requested` review folded in. After this plan, that amendment gets
one bounded adversarial pass scoped to the changed text, and the doctor cannot
call the plan `ready` while a P2-or-above amendment sits un-re-checked.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] `skills/mstack-run/scripts/amendment-repass.sh` exists, is committed mode
      `100755`, and implements four subcommands:
      `capture <plan> <round> <severity> <trigger>` (persist the pre-edit image
      of the plan file together with the classification — the full signature is
      spelled out in the next criterion, and there is no 2-argument form: a
      capture without severity is what leaves `assert-rechecked` with nothing to
      assert over),
      `diff <plan> <round>` (print the unified diff pre-image → current, the
      only text the re-pass reviewer is given),
      `record <plan> <round> <severity> <trigger> <by>` (append a re-check
      record), and
      `assert-rechecked <plan>` (exit `EXIT_AMENDMENT_UNCHECKED` (39) when any
      recorded P2-or-above amendment for that plan has no matching re-check
      record).
- [ ] **The severity signal is produced by this plan, not assumed.** Nothing in
      the pipeline currently classifies an amendment. `capture` therefore takes
      the triggering finding's severity and class as arguments and stores them
      with the pre-image:
      `capture <plan> <round> <severity: p1|p2|p3> <trigger: audit-genuine|seam-blocking|frame-critical|review-edit|autofix-autonomy|autofix-verification|autofix-trap|autofix-mechanical>`.
      All four arguments are required — there is no short form. What IS
      tolerated is an *unrecognized* severity token (a caller passing
      `unknown`, or a value outside `p1|p2|p3`): that stores `p2`, because
      unknown means "needs the re-check", never "skip it". A call with fewer
      than four arguments is a usage error, exits nonzero, and writes nothing;
      silently defaulting a missing argument is how the classification signal
      would rot back to absent.
- [ ] **The doctor is the producer, and the capture sites are enumerated, not
      implied.** Today's auto-fix phases emit free-text logs, not typed events
      (`SKILL.md:567-581`, `SKILL.md:607-612`), so this plan must name every
      site that calls `capture` and with what severity. The Step 4b wiring adds
      a `capture` call at exactly these seven points, each stamping the severity
      and trigger shown:
      GENUINE audit auto-fix → `p2 audit-genuine`;
      blocking SEAM fix → `p2 seam-blocking`;
      `[critical]` frame fix → `p2 frame-critical`;
      autonomy auto-fix → `p3 autofix-autonomy`;
      verification/testability auto-fix → `p3 autofix-verification`;
      trap-resistance auto-fix → `p3 autofix-trap`;
      mechanical-error auto-fix → `p3 autofix-mechanical` (`SKILL.md:1138-1141`
      — Step 4b's own list of plan-transforming edits names it at
      `SKILL.md:1177-1179`, so omitting it would leave a real edit path
      uncaptured).
      A P3 site escalates to `p2` when the finding that triggered it was itself
      P2+. The same table goes in `AGENTS.md`.
- [ ] **The review path captures around the invocation, not at a fix site.**
      Step 5's `changes-requested` branch records a verdict and applies no fix
      (`SKILL.md:1322-1334`) — the plan edit, when there is one, comes from the
      review skill itself, which is why Step 5 already has a "Re-validate
      review-edited plans" pass. So the capture is taken **before invoking the
      review skill** and the amendment is recognized after it returns if the
      plan's hash changed: trigger `review-edit`, severity `p2` (a reviewer's
      edit is exactly the class of amendment this rule exists for). Do not wire
      capture into the `changes-requested` bookkeeping branch; there is no fix
      there to capture.
- [ ] Records live in `.mstack/amendments/plan-<id>.jsonl`, one line per capture
      and per re-check, with the pre-images under
      `.mstack/amendments/plan-<id>-r<N>.pre`. `.mstack/` is gitignored, so this
      record is **local and non-authoritative by construction** — the same
      caveat the `.mstack/reviews/*.json` cache carries, and it must be stated
      wherever the record is described rather than discovered later.
- [ ] `mstack-plan-doctor` Step 4b runs the re-pass **inside the bounded loop**:
      after an edit round produces `MODIFIED_PLANS`, for each modified plan with
      a P2+ amendment, one focused pass over `amendment-repass.sh diff` output
      only, with the brief "assume this fix introduced a new defect; find it" —
      routed through the outside voice (codex) when available, using plan 090's
      premise-attack framing, and run as a same-model pass when codex is not.
      The re-pass reviewer sees the diff and the plan's acceptance criteria, not
      the whole plan: scope is what keeps it one bounded pass.
- [ ] A defect found by the re-pass is handled exactly like a GENUINE audit
      finding: auto-fix if unambiguous (which produces a new amendment, captured
      and re-checked in the next round), otherwise surface as blocking and force
      `needs-fixes`. The existing 3-round cap bounds this; the re-pass adds no
      new loop.
- [ ] The Step 4 report gains an `AMEND` row per amended plan:
      `AMEND [p2 audit-genuine] round 2 — re-checked: yes (codex), 0 defects`
      or `... re-checked: no`. Plans cited as `NNN: Title`.
- [ ] `mstack-plan-doctor` Step 6 refuses `ready` for any plan whose
      `assert-rechecked` exits 39, reporting it as `needs-fixes` with the
      un-re-checked amendment named. This is the mstack analogue of the
      proposal's "CLEARED requires it for any P2+ amendment".
- [ ] Gated on `rule_enabled amendment_repass` (the helper from 088). Disabled,
      the doctor prints the mode line, skips capture/re-pass, and Step 6 does not
      consult `assert-rechecked`. Rules 1, 3, and 4 are unaffected by that key.
- [ ] `skills/mstack-run/scripts/amendment-repass-smoke.sh` exists, is `100755`,
      and passes: capture-then-diff round-trips the exact edited text; a P2
      capture with no re-check exits 39; the same with a re-check recorded exits
      0; a P3 capture with no re-check exits 0; a capture with an unrecognized
      severity token is treated as P2 (exits 39 un-re-checked); a capture call
      with fewer than four arguments exits nonzero and writes nothing; a plan
      with no amendments at all
      exits 0; and the disabled path exits 0 without writing records.
- [ ] `rule-toggle-smoke.sh` gains an `amendment_repass` independence case.
- [ ] `AGENTS.md` documents the rule, the severity table, and the honest
      residual: this is an honest-path check only. It fires when the doctor
      calls `capture`; an agent that edits a plan without capturing leaves no
      record, and `assert-rechecked` on a plan with no records exits 0. There is
      no write-time hook and no retroactive audit for this, and claiming
      otherwise would repeat the overclaim plan 039 explicitly refused to make
      about uncommitted work.

## Design

**Rule 2 is last because it costs the most and depends on the other three.** It
reuses 088's toggle helper, 090's premise-attack brief for the re-pass reviewer,
and the report/step conventions 088–089 establish. Sequencing it earlier would
mean building the amendment record before the thing that briefs its reviewer
exists.

**The classification gap is real and this plan closes it.** Step 4b today knows
only that a plan's hash changed. Which finding drove the edit, and how severe it
was, is information the doctor holds at edit time and immediately discards. So
`capture` takes severity and trigger as arguments — the producer is the doctor
step that is already acting on a classified finding, and the storage is this
script. Without that, `assert-rechecked` would have nothing to assert over.

**Unknown severity resolves to P2.** The cost asymmetry is the same one the
review gate settles the same way: a needless re-pass costs one bounded call; a
skipped re-pass on a fix that introduced a P1 costs what the 051–053 batch cost.

**Scope discipline is what keeps this bounded.** The re-pass reviewer gets the
amendment diff and the acceptance criteria — not the plan, not the repo. The
proposal prices this at roughly 15 minutes against three amended sections, and
the cost holds only if the input stays the diff. A re-pass that re-reads the
whole plan is just a second full review under a different name.

**Why the record is `.jsonl` under `.mstack/`.** It is per-checkout working
state, not a durable contract — the same class as `health-history.jsonl` and the
reviews cache. It is deliberately NOT frontmatter: the `reviews:` block is the
completion gate's single source of truth and its values may not contain spaces,
so amendment records have no business there, and adding a fifth review type
would entangle Rule 2 with the completion gate this plan does not touch.

Testing approach: unit-only (shell helper and skill prose; no user-facing
surface).

**Files expected to change:**

- `skills/mstack-run/scripts/amendment-repass.sh`: NEW. The four subcommands,
  the record format, the severity default, exit 39.
- `skills/mstack-run/scripts/amendment-repass-smoke.sh`: NEW. Seven cases from
  the acceptance criteria.
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: add the new
  suite to the hardcoded list (shipped source first, then copy).
- `CHANGELOG.md`: one entry covering all four shipped rules (this is the last
  plan in the goal, so it carries the batch entry).
- `skills/mstack-run/scripts/rule-toggle-smoke.sh`: add the `amendment_repass`
  case.
- `skills/mstack-run/scripts/lib.sh`: add `EXIT_AMENDMENT_UNCHECKED=39` with a
  documenting comment block (35 reserved for pending plan 087, 36 =
  health-internal, 37 = premise lint from plan 088, 38 = tui fixture from plan
  089).
- `skills/mstack-plan-doctor/SKILL.md`: Step 4b gains capture + the re-pass;
  Step 4 gains the `AMEND` row; Step 6 gains the `assert-rechecked` gate.
- `AGENTS.md`: the rule, the severity table, and the honest residual.
- `docs/review-hardening-proposal.md`: mark Rule 2 adopted with its plan id.

**Out of scope:** any change to `review-gate.sh`, the `reviews:` frontmatter
block, the completion gate, or the Step 7a sequence — an amendment record is not
a review verdict and must not become one; adding a write-time hook or a
retroactive audit for amendments (deliberately not claimed); re-passing
amendments made outside plan-doctor (e.g. a hand-edit in an editor — out of
reach by construction); editing gstack review skills.

## Tasks

1. Add `EXIT_AMENDMENT_UNCHECKED=39` to `lib.sh` with its comment block.
2. Write `amendment-repass-smoke.sh` first; confirm it fails before the script
   exists. `chmod +x` and `git update-index --chmod=+x`.
3. Write `amendment-repass.sh`: the four subcommands, `.mstack/amendments/`
   layout, strict 4-arity on `capture` (missing argument = usage error, writes
   nothing; unrecognized severity token = stored p2), the `rule_enabled
   amendment_repass` gate and mode line, exit 39.
4. Wire plan-doctor Step 4b: a `capture` call at each of the seven enumerated
   auto-fix sites plus the Step 5 around-the-review site, each stamping its
   severity and trigger; run the scoped re-pass for P2+ amendments using plan
   090's brief; record the result.
5. Add the `AMEND` report row (Step 4) and the `assert-rechecked` gate (Step 6).
6. Extend `rule-toggle-smoke.sh` with the `amendment_repass` case; add
   `amendment-repass-smoke.sh` to `skills/mstack-run/hooks/pre-commit`, copy to
   `.githooks/pre-commit`, and list it in `AGENTS.md`.
7. Document the rule, the severity table, and the honest residual in
   `AGENTS.md`; mark Rule 2 adopted in the proposal doc; add a CHANGELOG entry
   covering the whole four-rule set.
8. Run the full smoke battery, `bash -n`, and `shellcheck` over the changed
   scripts.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/amendment-repass-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/rule-toggle-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash -n skills/mstack-run/scripts/amendment-repass.sh skills/mstack-run/scripts/amendment-repass-smoke.sh skills/mstack-run/scripts/lib.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/amendment-repass.sh skills/mstack-run/scripts/amendment-repass-smoke.sh`
- [cmd] `grep -q "EXIT_AMENDMENT_UNCHECKED=39" skills/mstack-run/scripts/lib.sh`
- [cmd] `grep -q "AMEND" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q "assert-rechecked" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -qi "amendment" AGENTS.md`

## Implementation Notes

Rule 2 completes the four-rule set. `amendment-repass.sh` (exit 39, strict
4-arity `capture`, an unrecognized severity token stored as `p2`, gated on
`rules.amendment_repass` with its mode line) gives plan-doctor somewhere to
record an amendment and its classification, so a P2+ fix the doctor itself
wrote cannot reach `ready` without one bounded adversarial pass over the
amendment diff alone. Plan-doctor gains the enumerated capture sites, the
scoped re-pass, the `AMEND` report row, and the Step 6 `assert-rechecked` gate.

Two implementation decisions beyond the spec, both recorded rather than
folded in silently:

- `record` takes an optional 6th `<defects>` argument (default 0), because the
  `AMEND` report row needs a defect count and nothing else stores one.
  `capture` stays strictly 4-arity as specified.
- `record` REFUSES a round with no matching capture. A mis-numbered round would
  otherwise look recorded, exit 0, and leave the real amendment un-re-checked —
  a false clearance produced by an off-by-one, which is the same
  silence-looks-like-success failure this rule exists to close.

The gate was demonstrated failing, not assumed to work: a captured p2 amendment
with no re-check exits 39, and exits 0 once the re-check is recorded. The demo
records were deleted afterwards — a fabricated "re-checked" entry must not sit
in the ledger.

**Honest residual, stated here as in `AGENTS.md`:** this is an HONEST-PATH check
only. It fires when the doctor calls `capture`; an agent that edits a plan
without capturing leaves no record, and `assert-rechecked` on a plan with no
records exits 0. There is no write-time hook and no retroactive audit for
amendments, and none is claimed — the same refusal to overclaim that plan 039
made about uncommitted work.

**Files changed:**

- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/rule-toggle-smoke.sh` (modified)
- `skills/mstack-plan-doctor/SKILL.md` (modified)
- `skills/mstack-run/hooks/pre-commit` (modified)
- `.githooks/pre-commit` (modified)
- `AGENTS.md` (modified)
- `docs/review-hardening-proposal.md` (modified)
- `CHANGELOG.md` (modified)
- `skills/mstack-run/scripts/amendment-repass.sh` (created)
- `skills/mstack-run/scripts/amendment-repass-smoke.sh` (created)

**Commit:** `9d1ba65` — `feat(plan 091): amendment re-pass for review fixes`
