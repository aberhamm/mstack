---
id: 027
title: Adversarial cross-model audit mode for plan-doctor
status: pending
blocked-by: [026]
priority:
goal: doctor-autonomy-hardening
allows-migrations: false
needs-review: none
created: 2026-06-26
---

## Requirements

plan-doctor's deep validation runs same-model sub-agents handed the plan's own
framing ("verify these claims"), which biases toward confirming the plan's
narrative. Ground-truth contradictions that an independent model catches are
missed. (Observed: an independent Codex pass found a real blocker — a plan
assumed a server-rendered partial that does not exist — plus several contract
errors that the same-model validators had confirmed as fine. Monoculture review
has a ceiling.)

Add an adversarial cross-model audit pass to plan-doctor that, when an external
model is available, audits each plan against the real source with a skeptical,
falsify-first rubric, and folds genuine findings into the report.

**Acceptance criteria:**

- [ ] plan-doctor gains "Step 3.5: Adversarial cross-model audit", running after
      structural validation (Step 3) and before the report (Step 4).
- [ ] Provider selection honors `.mstack/config.json` `review.provider`, reusing
      the discovery pattern from `mstack-code-review`. SUPPORTED in this plan:
      `codex` (and `auto` when codex is present). `claude-only`, `gemini`, or no
      external binary → the step is SKIPPED with a logged note (never an error).
      `gemini` support is explicitly DEFERRED (out of scope); if `review.provider`
      is `gemini`, log "adversarial audit: gemini not yet supported, skipping"
      rather than inventing behavior.
- [ ] When codex is available, the doctor shells out per plan with
      `codex exec --sandbox read-only` plus the established filesystem-boundary
      preamble (same pattern as `mstack-plan-multi` structural-critique),
      passing an adversarial rubric: verify claims against actual source, find
      what a confirmatory reviewer would miss, cite `file:line`.
- [ ] Findings are classified by a DETERMINISTIC rule: a finding is
      FORWARD-DEPENDENCY iff it references a file/symbol/endpoint that a
      blocked-by ancestor which is NOT yet `done` declares it will produce
      (in that ancestor's "Files expected to change" / Design — or, once plan 028
      lands, that ancestor's `mstack:seam` produced block). Otherwise GENUINE.
      FORWARD-DEPENDENCY findings are noted, non-blocking; GENUINE are blocking.
- [ ] On a GENUINE finding, the doctor AUTO-TRIGGERS a plan edit that addresses
      it (same auto-fix discipline as autonomy/verification fixes), which marks
      the plan MODIFIED so plan 026's loop re-validates it AND re-runs the audit
      on the modified plan. If a GENUINE finding cannot be auto-resolved (genuine
      ambiguity), it is surfaced as a blocking finding → `needs-fixes`, never
      silently `ready`. The 3-round cap (plan 026) bounds any fix↔audit cycle.
- [ ] The audit is bounded and fault-tolerant: read-only sandbox, per-plan
      timeout (300s), parallel across plans where supported. On codex non-zero
      exit, timeout, empty/malformed output, or missing `file:line`, the audit
      for THAT plan is logged as "audit-inconclusive" and skipped (never stalls,
      never fabricates a finding); other plans proceed.

## Design

Reuse, do not reinvent. The `codex exec` invocation + security preamble already
exist in `skills/mstack-plan-multi/references/structural-critique.md`; the
provider discovery + `review.provider` preference already exist in
`mstack-code-review` and `skills/mstack-run/scripts/config.sh`. This plan ports
that machinery into plan-doctor with an audit-specific (ground-truth,
adversarial) rubric and a forward-dependency classifier.

**Files expected to change:**

- `skills/mstack-plan-doctor/SKILL.md`: add a Discovery line (mirror
  code-review: `command -v codex`; read `review.provider`) and "Step 3.5:
  Adversarial cross-model audit" with per-plan codex-exec fan-out,
  classification, and merge-into-report wiring.
- `skills/mstack-plan-doctor/references/adversarial-audit.md` (new): the
  adversarial rubric, the LITERAL `codex exec --sandbox read-only -c
  'model_reasoning_effort="high"'` command with the no-skill-dirs
  filesystem-boundary preamble, the per-plan prompt template (how the plan text
  and the source-file context are injected, stdin `< /dev/null`, stderr capture
  to a tempfile, `timeout: 300000`), the expected output schema (a finding =
  severity + `file:line` + claim), the deterministic GENUINE-vs-FORWARD-DEPENDENCY
  classifier, the auto-fix-on-GENUINE procedure, the fault-tolerance rules
  (non-zero/timeout/malformed → audit-inconclusive), and the report-merge format.
  Loaded on demand via the same `> **Read** "$SKILL_DIR/references/..."` directive
  pattern the skill already uses (Step 0b/trap/frame references) — there is no
  separate "section index".

**Out of scope:** changing the same-model validators; adding the seam-contract
finding category (plan 028); the re-validate loop itself (plan 026, a
dependency). Do not modify the read-only source patterns in
`mstack-plan-multi`/`mstack-code-review`.

## Tasks

1. Add a Discovery snippet to plan-doctor mirroring code-review
   (`command -v codex`; read `review.provider` via `config.sh get`). Decide
   run vs skip-with-note: run only for `codex`/`auto`-with-codex; skip (logged)
   for `claude-only`, `gemini`, or no binary.
2. Write `references/adversarial-audit.md`: the rubric (verify-against-source,
   falsify-first, cite `file:line`, ~180 words/plan), the LITERAL
   `codex exec --sandbox read-only -c 'model_reasoning_effort="high"'` command
   with the boundary preamble, the per-plan prompt template (plan-text + source
   context injection, `< /dev/null`, stderr→tempfile, `timeout: 300000`), and
   the expected finding output schema.
3. Add the deterministic classifier: a finding referencing a file/symbol/endpoint
   declared by a NOT-yet-`done` blocked-by ancestor (its "Files expected to
   change"/Design, or `mstack:seam` produced block once 028 lands) →
   FORWARD-DEPENDENCY (noted, non-blocking); otherwise GENUINE (blocking).
4. Add the auto-fix-on-GENUINE procedure: apply a plan edit addressing the
   GENUINE finding (marking the plan MODIFIED for plan 026's loop); if it cannot
   be auto-resolved, surface it as a blocking finding → `needs-fixes`.
5. Add "Step 3.5" to SKILL.md: fan out one read-only codex audit per plan
   (parallel, 300s timeout each), with fault-tolerance (non-zero/timeout/
   malformed → audit-inconclusive, skip that plan, never stall); collect,
   classify, auto-fix GENUINE, and merge findings into the Step 4 report and the
   Step 4b re-validation set.
6. Gate the step behind availability + `review.provider`; skip-with-note when
   unavailable.

## Verification

Checks:
- [cmd] test -f skills/mstack-plan-doctor/references/adversarial-audit.md
- [assert] grep -ni "Step 3.5" skills/mstack-plan-doctor/SKILL.md | grep -i "audit"
- [cmd] grep -qE "codex exec --sandbox read-only" skills/mstack-plan-doctor/references/adversarial-audit.md
- [cmd] grep -qiE "forward.dependency" skills/mstack-plan-doctor/references/adversarial-audit.md
- [cmd] grep -qiE "audit.inconclusive|timeout|malformed" skills/mstack-plan-doctor/references/adversarial-audit.md
- [cmd] grep -qiE "GENUINE" skills/mstack-plan-doctor/references/adversarial-audit.md
- [cmd] grep -qiE "auto.?fix|auto.?trigger|apply .* edit" skills/mstack-plan-doctor/references/adversarial-audit.md
- [cmd] grep -qiE "review\.provider" skills/mstack-plan-doctor/SKILL.md
- [manual] with codex installed, run plan-doctor on a plan that contradicts the source; confirm the audit flags it GENUINE, auto-edits the plan, and 026's loop re-audits the result
- [manual] simulate a codex timeout/non-zero exit; confirm the audit logs audit-inconclusive for that plan and other plans still proceed
