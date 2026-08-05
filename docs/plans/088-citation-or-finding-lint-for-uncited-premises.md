---
id: 088
title: Citation-or-finding lint — an uncited factual premise is a finding
status: done
blocked-by: []
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

Rule 1 of `docs/review-hardening-proposal.md`. Today the plan pipeline verifies
what a plan *cites* and exempts what it *asserts*. That asymmetry is backwards,
and it is exactly how the two P1s in the cctrl 051–053 batch escaped two
reviews: both were the batch's only uncited premises about existing code
("the picker is a modal, so `_session_rich_state` should report
`blocked-dialog`" cited nothing), while every cited claim in the same plans —
line refs, JSON key counts, measured timings — had been checked. Decorating a
claim with a citation *attracted* verification; omitting one *bought exemption*.

The user is the architect running `/mstack-plan-doctor` on a backlog before
walking away. Today the doctor tells them a plan's checks exist, that its seams
line up, and that codex could not falsify its cited claims. It says nothing
about the claims the plan never cited. After this plan, the doctor names them.

**Acceptance criteria** (the autonomous worker treats these as the test
oracle, so be specific):

- [ ] `skills/mstack-run/scripts/premise-lint.sh lint <plan-ref-or-path>`
      exists, is committed mode `100755`, and classifies every acceptance
      criterion in the plan into exactly one of four classes, one line per AC
      on stdout: `CITED-OK`, `CITED-UNRESOLVED`, `UNCITED`, `NO-PREMISE`.
- [ ] `CITED-UNRESOLVED` is emitted when an AC cites a backticked identifier
      (a `snake_case`/`camelCase` symbol or a repo-relative path) that appears
      **nowhere** in the repository's tracked-or-untracked working tree AND that
      the plan's `**Files expected to change:**` never declares it will create.
      Resolution works differently for the two citation shapes, and the
      difference is what keeps the class reachable:
      a **path** citation resolves by path existence anywhere in the working
      tree, plan files included (a plan citing
      `docs/plans/087-detect-shipped-but-unclosed-plans.md` is citing a real
      artifact);
      a **symbol** citation resolves only against the CONTENT of non-plan files
      — `docs/plans/` and its `archive/` are excluded from that content search.
      Without that exclusion the symbol class is unreachable by construction:
      the symbol is being read *out of a plan file*, so a repo-wide content
      search always finds it in the very plan under lint and every unresolvable
      citation resolves. The smoke suite must include a case that would pass if
      the exclusion were dropped.
      This class is deterministic and provable, so it is **BLOCKING**: the
      script exits `EXIT_PREMISE_UNCITED` (37) when at least one is found.
- [ ] `UNCITED` is emitted when an AC carries a premise signal about existing
      code but cites no identifier at all. The premise-signal vocabulary is a
      single explicit list at the top of the script (`should`, `presumably`,
      `by construction`, `assumes`, `already`, `existing`, `current`,
      `currently`, `since`, `because`, `so that it reports`, `will report`),
      documented as tunable. `UNCITED` alone does NOT set the exit code —
      the script reports it and the doctor decides (next criterion).
- [ ] `UNCITED` findings are a **blocking finding class in the doctor's Step 4b
      gate unless resolved**: the doctor must either add the citation (locating
      the real function/file and rewriting the AC to name it) or rewrite the AC
      so it no longer asserts anything about existing code. An `UNCITED` finding
      that survives the Step 4b round cap forces `needs-fixes` and forbids
      `ready`, exactly as an unresolved GENUINE audit finding does. A plan is
      never silently `ready` with a load-bearing uncited premise.
- [ ] `lib.sh` gains `rule_enabled <key>`: reads `rules.<key>` from
      `.mstack/config.json` via `config.sh get`, returns 0 (enabled) unless the
      value is exactly `false`. **Absence, an unreadable config, or a degraded
      `json_get` fallback all mean ENABLED** — a lint that silently turns itself
      off is the plan-045 failure mode, and the cost asymmetry here points at
      running a rule the user disabled (noisy, obvious) over silently skipping
      one they wanted (invisible).
- [ ] Every consumer of `rule_enabled` **prints its mode** before acting:
      `[mstack] rule citation_or_finding: enabled` or `... : disabled (config)`.
      A degraded or disabled run must be legible as such, per the plan-045
      "a fail-safe default hides a dead feature" rule.
- [ ] `premise-lint.sh` is gated on `rule_enabled citation_or_finding`: when the
      key is `false` it prints the disabled line, emits no findings, and exits 0.
      Setting `rules.citation_or_finding=false` disables Rule 1 and
      nothing else.
- [ ] `mstack-plan-doctor` gains **Step 3.9** (after Step 3.8, before Step 4)
      that runs the lint per plan and renders findings as `PREMISE` rows in the
      Step 4 report, with the citation convention (`NNN: Title`, never a bare
      id) for any plan it names.
- [ ] `mstack-plan-doctor` Step 5 passes an explicit checklist line into the
      `/plan-eng-review` invocation context: "verify every cited premise against
      the cited code; file every uncited load-bearing premise as a finding."
      The gstack review skill itself is NOT edited — it lives outside this repo;
      the wiring is the context mstack passes in.
- [ ] `skills/mstack-run/scripts/premise-lint-smoke.sh` and
      `skills/mstack-run/scripts/rule-toggle-smoke.sh` exist, are `100755`, and
      pass. The premise smoke covers, on temp-dir fixtures: an AC citing a
      symbol that exists (`CITED-OK`, exit 0); an AC citing a symbol that
      exists nowhere (`CITED-UNRESOLVED`, exit 37); an AC citing a symbol the
      plan itself declares it will create (`CITED-OK`, exit 0 — forward
      reference, not a defect); an AC with a premise signal and no citation
      (`UNCITED`, exit 0, finding reported); a plain AC (`NO-PREMISE`); and the
      disabled path (exit 0, no findings, mode line printed).
- [ ] `AGENTS.md` documents Rule 1's mechanism, its blocking calibration, and
      the `rules.*` toggle namespace, including the honest residual that
      the `UNCITED` heuristic is a word-list and will both miss premises and
      flag prose that is not one.

## Design

**Where this fits.** The pipeline already has a scale of deterministic
plan-stage linters — `verify-lint.sh` (do the checks work), `health-reach.sh`
(does the gate run the declared tests), `review-gate.sh` (is the review
recorded). This is the next one along the same seam: does the plan cite what it
depends on. It follows their conventions exactly — a standalone script under
`skills/mstack-run/scripts/`, an exit code from `lib.sh`'s registry, a
fixture-driven smoke suite, and a doctor step that consumes it.

**Calibration is the whole design.** This repo has already shipped an
over-blocking lint once: `verify-lint.sh` conflated PENDING with BROKEN and
flagged six well-formed plans as dead. So the two classes are split by whether
they are *provable*:

- `CITED-UNRESOLVED` is provable from the repo (the identifier is not there and
  no plan declares it will be). It blocks in the script, exit 37.
- `UNCITED` is a heuristic over prose. The script never blocks on it; it
  reports. The **doctor** turns it into a blocking finding only after its own
  auto-fix attempt fails, which is the same discipline Step 3.5 already applies
  to a GENUINE adversarial-audit finding. This keeps the deterministic layer
  honest and puts the judgment where judgment belongs.

**Forward references are not defects.** Two exemptions, and they are NOT the
same rule:

- The ancestor exemption is the one Step 3.5's classifier already states
  (`references/adversarial-audit.md:114-121`): a symbol a not-yet-`done`
  `blocked-by` ancestor declares it will produce. Reuse that rule verbatim; do
  not invent a second one.
- The **self exemption** is new to this lint and has no precedent in that
  classifier: a symbol this plan's own `**Files expected to change:**` declares
  it will create. The audit classifier does not cover this case because it
  audits claims about the *existing* repo, not a plan's forward references to
  its own output. State it as its own rule rather than implying the classifier
  already provides it.

Both yield `CITED-OK`.

**Search surface.** Resolve an identifier against git's own view of the working
tree — `git ls-files` ∪ `git ls-files --others --exclude-standard` — not a
`find` walk and not tracked-only. A plan authored in the same session that
created a file must see that file; plan 043 established this exact rule for the
health detector and the reason is identical. **For symbol content search, minus
the plans directory**, per the acceptance criterion above: plans quote the
symbols they cite, so searching plan content makes every symbol citation
self-resolving and the blocking class dead on arrival — the plan-045 failure
mode (a check that cannot fail looks exactly like a check that passes). Path
citations keep the full surface, because a path that exists is evidence
regardless of which directory it lives in.

**The toggle namespace.** `rules.<key>` in `.mstack/config.json`, one key
per rule, read through `rule_enabled` in `lib.sh`. This plan introduces the
helper and the first key (`citation_or_finding`); plans 089/090/091 each add
their own key and their own disable-path smoke case. That satisfies the
independence constraint at the granularity the user asked for: flipping one key
disables exactly one rule, and reverting one rule's commit touches one script,
one doctor step, and one smoke suite.

The key is deliberately **two levels** (`rules.<key>`, a new top-level `rules`
object), not `review.rules.<key>`. `json_get`'s awk fallback handles at most 2
levels (`lib.sh:145-168`), so a 3-level path would be unreadable without `jq` —
and since a degraded read must resolve to ENABLED, a 3-level key would make the
toggle silently inoperable on any machine without `jq`. Two levels means the
disable actually works in the fallback path. Add `"rules": {}` to `config.sh`'s
`DEFAULT_CONFIG` so `config.sh show` documents the namespace, and add the four
keys to `cmd_set`'s known-key validation (`true|false` only) so a typo is
rejected rather than silently ignored.

Testing approach: unit-only (shell helpers and skill prose; no user-facing
surface).

**Files expected to change:**

- `skills/mstack-run/scripts/premise-lint.sh`: NEW. `lint <plan>` subcommand,
  the four-class classifier, the premise-signal word list, exit 37.
- `skills/mstack-run/scripts/premise-lint-smoke.sh`: NEW. Fixture-driven suite
  covering all four classes plus the disabled path.
- `skills/mstack-run/scripts/rule-toggle-smoke.sh`: NEW. Asserts `rule_enabled`
  returns enabled on absent/garbled/missing config, disabled only on an exact
  `false`, and that the mode line prints in both directions.
- `skills/mstack-run/scripts/lib.sh`: add `EXIT_PREMISE_UNCITED=37` with its
  documenting comment block (following the existing style) and `rule_enabled`.
- `skills/mstack-run/scripts/config.sh`: add the `rules` object to
  `DEFAULT_CONFIG` and the four rule keys to `cmd_set`'s known-key validation.
- `skills/mstack-plan-doctor/SKILL.md`: add Step 3.9; add the `PREMISE` row to
  the Step 4 report format; add `UNCITED`-unresolved to Step 4b's
  blocking-finding set AND the Step 3.9 lint to Step 4b's per-modified-plan
  re-validation list; create the **review-invocation context block** in Step 5
  (which today says only "Pass the plan file path as context",
  `SKILL.md:1288-1294`) carrying the citation checklist line. Plan 090 appends
  its premise mandate to that same block.
- `skills/mstack-run/hooks/pre-commit` and `.githooks/pre-commit`: add both new
  suites to the hardcoded smoke list (shipped source first, then copy — a
  `.githooks`-only edit is clobbered by the next `mstack-init`/`setup`).
- `AGENTS.md`: document the rule, the calibration, and the toggle namespace.
- `docs/review-hardening-proposal.md`: mark Rule 1 as adopted, with a pointer
  to the implementing plan id.

**Out of scope:** editing the gstack `plan-eng-review` / `plan-design-review` /
`plan-ceo-review` skills (they live outside this repo — the wiring is the
context plan-doctor passes in); changing the adversarial audit's codex brief
(that is plan 090); any change to `review-gate.sh`, `pick-next.sh`,
`health-check.sh`, `result-gate.sh`, or the Step 7a completion sequence;
retro-fitting citations into the existing backlog's plans.

## Tasks

1. Add `EXIT_PREMISE_UNCITED=37` and `rule_enabled` to `lib.sh`, plus the
   `rules` object in `config.sh`'s `DEFAULT_CONFIG` and its `cmd_set`
   validation. **37, not 35**: `lib.sh:116` reserves 35 for pending plan 087's
   `EXIT_PLAN_SATISFIED`, and 36 is `EXIT_HEALTH_INTERNAL`. Plans 089 and 091
   take 38 and 39.
2. Write `rule-toggle-smoke.sh` FIRST and run it — it must fail before
   `rule_enabled` exists and pass after. `chmod +x` and
   `git update-index --chmod=+x`.
3. Write `premise-lint.sh`: plan-ref resolution via `resolve_plan_ref`, AC
   extraction from `## Requirements`, identifier extraction from backticks, the
   working-tree resolution set, the forward-reference exemption, the four
   classes, the `rule_enabled` gate + mode line, exit 37.
4. Write `premise-lint-smoke.sh` covering all six cases in the acceptance
   criteria on temp-dir fixtures. `chmod +x` and `git update-index --chmod=+x`.
5. Wire `mstack-plan-doctor`: Step 3.9, the `PREMISE` report row, the Step 4b
   blocking-set entry, the Step 4b re-validation-list entry, and the new Step 5
   review-invocation context block carrying the citation checklist line.
6. Add both suites to `skills/mstack-run/hooks/pre-commit`, copy to
   `.githooks/pre-commit`, and list them in `AGENTS.md`'s smoke battery.
7. Document the rule and the `rules.*` namespace in `AGENTS.md`; mark
   Rule 1 adopted in `docs/review-hardening-proposal.md`.
8. Run the full smoke battery (all suites listed in `AGENTS.md`, plus the two
   new ones), `bash -n`, and `shellcheck` over the changed scripts.

## Verification

Checks:

- [cmd] `bash skills/mstack-run/scripts/premise-lint-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/rule-toggle-smoke.sh`
- [cmd] `bash skills/mstack-run/scripts/script-mode-smoke.sh`
- [cmd] `bash -n skills/mstack-run/scripts/premise-lint.sh skills/mstack-run/scripts/premise-lint-smoke.sh skills/mstack-run/scripts/rule-toggle-smoke.sh skills/mstack-run/scripts/lib.sh`
- [cmd] `shellcheck skills/mstack-run/scripts/premise-lint.sh skills/mstack-run/scripts/premise-lint-smoke.sh skills/mstack-run/scripts/rule-toggle-smoke.sh`
- [cmd] `grep -q "EXIT_PREMISE_UNCITED=37" skills/mstack-run/scripts/lib.sh`
- [cmd] `grep -q "Step 3.9" skills/mstack-plan-doctor/SKILL.md`
- [cmd] `grep -q "rules" AGENTS.md`
- [cmd] `bash skills/mstack-run/scripts/premise-lint.sh lint 088`
  (this plan lints clean against itself — every identifier it cites resolves)

## Implementation Notes

Rule 1 shipped as `premise-lint.sh`, a deterministic four-class citation lint
(CITED-OK / CITED-UNRESOLVED / UNCITED / NO-PREMISE) gated on the new fail-open
`rules.<key>` toggle namespace, wired into `mstack-plan-doctor` as Step 3.9 plus
the Step 4b blocking set, the Step 4b re-validation list, and a new Step 5
review-invocation context block carrying the citation checklist line. Two new
smoke suites (26 checks) cover every acceptance case including the plans-dir
exclusion that keeps the blocking class reachable; both are in the pre-commit
battery.

Three latent defects surfaced and were fixed en route: `json_get`'s jq branch
used `// empty`, which swallows a literal `false` (the toggle would have been
dead on arrival, and `commit.conventional=false` had silently never taken
effect); the `Files expected to change` anchor was loose enough that a plan
discussing the mechanism matched it inside its own ACs, making the
forward-reference exemption universal; and `[a-z]*` in a `case` pattern matches
ALL-CAPS words under en_US.UTF-8 collation.

Out-of-declared-scope, disclosed: the repo's health gate was already red
(composite 4.0 on 2026-07-31 and again before this plan started) from 17
`SC2016` false positives in `verify-lint.sh`/`verify-lint-smoke.sh`. Scoped
`# shellcheck disable=SC2016` directives with explanations took the composite
4.0 -> 10.0. Also, this plan's own AC2 cited a placeholder path
(`docs/plans/087-foo.md`) that resolved nowhere; the lint flagged it correctly
and it was rewritten to the real file, per Rule 1's own remediation.

**Files changed:**

- `skills/mstack-run/scripts/lib.sh` (modified)
- `skills/mstack-run/scripts/config.sh` (modified)
- `skills/mstack-run/scripts/verify-lint.sh` (modified)
- `skills/mstack-run/scripts/verify-lint-smoke.sh` (modified)
- `skills/mstack-plan-doctor/SKILL.md` (modified)
- `skills/mstack-run/hooks/pre-commit` (modified)
- `.githooks/pre-commit` (modified)
- `AGENTS.md` (modified)
- `docs/review-hardening-proposal.md` (modified)
- `skills/mstack-run/scripts/premise-lint.sh` (created)
- `skills/mstack-run/scripts/premise-lint-smoke.sh` (created)
- `skills/mstack-run/scripts/rule-toggle-smoke.sh` (created)

**Commit:** `1a15e31` — `feat(plan 088): citation-or-finding lint for uncited premises`
