# Adversarial cross-model audit (plan-doctor Step 3.5)

This reference holds the full procedure for the adversarial cross-model audit:
the rubric, the literal `codex exec` command with its filesystem-boundary
preamble, the per-plan prompt template, the finding output schema, the
deterministic GENUINE-vs-FORWARD-DEPENDENCY classifier, the auto-fix-on-GENUINE
procedure, the fault-tolerance rules, and the report-merge format.

The same-model validators in Step 3 hand each sub-agent the plan's own framing
("verify these claims"), which biases toward confirming the plan's narrative.
This audit deliberately breaks that monoculture: an independent model reads the
**actual source** and tries to **falsify** the plan. It runs only when an
external `codex` model is available (see the Discovery gate in `SKILL.md`); for
`claude-only`, `gemini`, or a missing `codex` binary it is SKIPPED with a logged
note, never an error.

## Rubric (what the auditor is told to do)

The auditor is a skeptical, falsify-first reviewer. Its job is to find what a
confirmatory same-model reviewer would miss by checking the plan's claims
against ground truth in the repository:

- **Verify every concrete claim against the actual source.** If the plan says a
  function, endpoint, partial, type, column, or file exists or behaves a certain
  way, open the real file and confirm. A claim that does not match the source is
  a finding.
- **Falsify first.** Assume the plan is wrong until the source proves it right.
  Do not restate the plan's reasoning back as agreement.
- **Find what a confirmatory reviewer misses:** unstated assumptions about
  existing code, contracts the plan relies on that the source does not provide,
  signatures/shapes that differ from what the plan asserts.
- **Cite `file:line` for every finding.** A finding with no `file:line` anchor is
  not actionable and is treated as malformed (see fault tolerance).
- **Be concise: roughly 180 words per plan.** Report only real, source-backed
  problems. If the plan matches the source, say so in one line.

## Premise-attack mandate (Rule 4, plan 090)

The rubric above says *what* to check. This says what to check **first**, and
what not to spend the run on at all.

**The outside voice is not a second primary reviewer.** In the cctrl 051-053
batch the cross-model channel came back "No tension — Codex sharpened two review
findings rather than disputing them", and the batch shipped two P1 defects
anyway. Two models handed the same framing produce independence of *style*, not
independence of *attention*. So the brief below tells the auditor, in as many
words, **do not sharpen or extend the primary reviewer's findings** — that work
is already done, and repeating it is what produced the false clearance.

What it attacks instead is the plan's **premises** — the things it treats as
already true about existing code — in this priority order:

- **(a) The plan's uncited factual claims**, taken verbatim from
  `premise-lint.sh`'s `UNCITED` lines (Rule 1, plan 088) and injected as the
  `UNCITED PREMISES (attack these first):` section. An assertion about existing
  code that cites nothing is the premise most likely to be wrong and least
  likely to have been checked by anyone upstream.
- **(b) Every "should / presumably / by construction / obviously" sentence.**
  Each names a premise the author did not think needed evidence.
- **(c) Any premise whose failure would invalidate a whole acceptance
  criterion** rather than a detail. One of these outranks any number of local
  detail findings.

**The `UNCITED PREMISES` section is omitted entirely when there is nothing to
put in it** — heading included. Never send it empty, and never send it with
"none found": the lint reports UNCITED heuristically and gives no clearance, so
a "none found" line would read to the auditor as a clean bill the lint never
issued. Absent section = no worklist, priority (b) leads. It is likewise omitted
when Rule 1 is disabled, for the same reason: no lint ran, so there is nothing
to report either way. Rule 4 reads Rule 1's output when it exists and degrades
to (b)/(c) targeting when it does not — a one-directional dependency, never a
breakage.

**The mandate is the only thing this changes.** The invocation mechanics, the
`FINDING:` schema, the GENUINE-vs-FORWARD-DEPENDENCY classifier, and the
fault-tolerance rules below are untouched by plan 090.

### The `premise_brief` gate and the pre-090 fallback

Gate the mandate on Rule 4's own toggle before composing the prompt, and print
the mode line so a degraded run is legible as degraded (plan 045):

```bash
if bash -c '. "$1/scripts/lib.sh"; rule_mode_line premise_brief' _ "$RUN_SKILL_DIR"; then
  PREMISE_BRIEF=on
else
  PREMISE_BRIEF=off
fi
```

- `PREMISE_BRIEF=on` (every state except an explicit `rules.premise_brief=false`)
  → send the premise-attack brief below, with the `UNCITED PREMISES` section
  when the lint produced lines.
- `PREMISE_BRIEF=off` → send **the pre-090 confirmatory-hunt brief** (kept
  verbatim under "Fallback brief" below), send no `UNCITED PREMISES` section,
  and skip the no-tension trigger in `SKILL.md` Step 3.5 entirely. Say which
  brief is in use: `adversarial audit: rule premise_brief disabled — using the
  pre-090 falsify-first brief, no premise pass`.

## The literal codex command (ported from structural-critique.md)

Reuse the exact invocation and filesystem-boundary preamble established in
`skills/mstack-plan-multi/references/structural-critique.md`. Do NOT reinvent
it. Run one read-only audit per plan, capture stderr to a tempfile, feed stdin
from `/dev/null`, and wrap the Bash call with `timeout: 300000` (300s):

```bash
TMPERR=$(mktemp "${TMPDIR:-/tmp}/codex-audit-err-XXXXXX")
codex exec --sandbox read-only -c 'model_reasoning_effort="high"' "IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, ~/.codex/skills/, .claude/skills/, .agents/skills/, or agents/. Stay focused on repository code only.

You are the OUTSIDE VOICE auditing one implementation plan for an autonomous AI worker. A primary reviewer has already read this plan for internal coherence and has already sharpened its details. That work is DONE. Do not sharpen or extend the primary reviewer's findings, and do not restate the plan's own reasoning back as agreement. Repeating either is what produced a false clearance on the batch this mandate comes from.

Your job is to attack the plan's PREMISES: the things it treats as already true about the existing code. Read the ACTUAL source files in this repository and try to FALSIFY them, in this priority order:

(a) The uncited factual claims listed under UNCITED PREMISES below, if that section is present. Take them first. An assertion about existing code that cites nothing is the premise most likely to be wrong and least likely to have been checked.
(b) Every sentence containing should, presumably, by construction, or obviously. Each one names a premise the author did not think needed evidence. Check what the source actually does.
(c) Any premise whose failure would invalidate a WHOLE acceptance criterion rather than a detail. One of these outranks any number of local detail findings, so hunt for it before polishing anything smaller.

Rules:
- Verify against the real files. Assume the premise is false until the source proves it true.
- Cite file:line for EVERY finding. A finding with no file:line is not actionable.
- Be concise: about 180 words. Report only real, source-backed problems. If the plan's premises hold against the source, say so in one line — do not manufacture tension.

For each finding, output exactly one line:
FINDING: <critical|high|medium> | <file:line> | <the false-or-unsupported claim and what the source actually shows>

UNCITED PREMISES (attack these first):
<the UNCITED lines premise-lint.sh emitted for this plan — OMIT THIS ENTIRE SECTION, heading included, when there are none>

PLAN UNDER AUDIT:
<full plan text>

SOURCE CONTEXT (paths the plan touches):
<the 'Files expected to change' paths, plus any files the plan names, so the auditor knows where to look>" \
  < /dev/null 2>"$TMPERR"
```

Use `timeout: 300000` on the Bash call. The `< /dev/null` keeps codex from
blocking on stdin; `2>"$TMPERR"` captures diagnostics for the inconclusive path
below.

**The `mktemp` template must END in `X`s — do not add a `.txt` suffix.** BSD/macOS
`mktemp` rejects a template with trailing characters after the `X`s and fails
with the thoroughly misleading `mkstemp failed: File exists`, which aborts the
audit before codex ever runs. GNU `mktemp` tolerates it, so this breaks only on
macOS — i.e. silently, on the machine most likely to be running it.

### Per-plan prompt template (how context is injected)

- **`<full plan text>`**: the entire plan file under audit (frontmatter +
  Requirements + Design + Tasks + Verification), so the auditor sees every claim.
- **`<source context>`**: the plan's `**Files expected to change:**` paths plus
  any other files/symbols/endpoints the plan names by hand. These point the
  read-only auditor at the ground-truth files; it still reads them itself inside
  the sandbox.
- **`<the UNCITED lines …>`**: the `UNCITED` lines `premise-lint.sh lint <plan>`
  emitted for THIS plan at Step 3.9, pasted verbatim (they already carry the AC
  index and an excerpt). Filter the lint output to lines whose first
  whitespace-delimited token is `UNCITED`; ignore `CITED-OK`, `NO-PREMISE`, and
  the mode line. **Zero such lines ⇒ drop the heading and the placeholder
  together** — the section never ships empty and never ships "none found". Same
  when Rule 1 is disabled or its lint was inconclusive: no lint output, no
  section.
- One codex invocation per plan. Fan out across plans in parallel where the host
  supports concurrent Bash calls; each call keeps its own `TMPERR` and its own
  `timeout: 300000`.

### Fallback brief (used when `rules.premise_brief=false`)

The pre-090 brief, kept verbatim so the disable is a real revert and not a
half-brief. When `PREMISE_BRIEF=off`, substitute this block for everything
between the filesystem-boundary preamble and the `For each finding` line, and
send no `UNCITED PREMISES` section:

```
You are adversarially auditing one implementation plan for an autonomous AI worker. Your job is to FALSIFY the plan, not confirm it. Read the ACTUAL source files in this repository and check every concrete claim the plan makes against ground truth.

Hunt specifically for what a confirmatory same-model reviewer would miss:
- Claims about code that does not match the source: a function, endpoint, partial, type, column, or file the plan assumes exists or behaves a certain way but does not.
- Unstated assumptions: contracts/shapes/signatures the plan relies on that the source does not actually provide.
- Approach conflicts: does the plan's approach contradict how the existing architecture actually works?

Rules:
- Verify against the real files. Assume the plan is wrong until the source proves it right.
- Cite file:line for EVERY finding. A finding with no file:line is not actionable.
- Be concise: about 180 words. Report only real, source-backed problems. If the plan matches the source, say so in one line.
```

## Expected finding output schema

Each finding is one line the doctor parses deterministically:

```
FINDING: <severity> | <file:line> | <claim>
```

- `severity`: `critical` | `high` | `medium`.
- `file:line`: a real repository path and line anchor (e.g. `app/views/foo.erb:42`).
  A finding missing this anchor is malformed.
- `claim`: the false-or-unsupported assertion and what the source actually shows.

A run that emits no `FINDING:` lines and a clean "matches the source" statement
is a PASS for that plan (no findings, audit conclusive).

## Deterministic GENUINE-vs-FORWARD-DEPENDENCY classifier

Every well-formed finding is classified by a deterministic rule — no judgment
call about severity changes the class:

- A finding is **FORWARD-DEPENDENCY** iff the `file:line` / symbol / endpoint it
  references is something a `blocked-by` ancestor that is **NOT yet `done`**
  declares it will produce. "Declares it will produce" means the referenced
  path/symbol appears in that ancestor's `**Files expected to change:**` or
  Design section — or, once plan 028 lands, in that ancestor's `mstack:seam`
  **produced** block. The plan legitimately depends on output that does not
  exist yet because the ancestor has not run; this is expected, not a defect.
  FORWARD-DEPENDENCY findings are **noted, non-blocking**.
- Otherwise the finding is **GENUINE**: the plan contradicts ground truth and no
  not-yet-done ancestor is on the hook to make the claim true. GENUINE findings
  are **blocking**.

Walk only the transitive `blocked-by` ancestors whose `status` is not `done`.
A done ancestor's output already exists in the source, so a mismatch against it
is GENUINE (the source is the truth), not a forward dependency.

## Auto-fix on GENUINE

On a GENUINE finding, apply the same auto-fix discipline used for
autonomy-readiness and verification fixes:

1. **Apply a plan edit that addresses the finding** — correct the false claim,
   adjust the Design/Tasks to match the real source, or add the missing
   prerequisite the source revealed. Edit the plan file in place.
2. Editing the plan changes its content hash, so it enters the `MODIFIED_PLANS`
   set. This **marks the plan MODIFIED** so plan 026's Step 4b loop re-validates
   it AND **re-runs the audit on the modified plan** (the per-modified-plan audit
   slice in Step 4b). The 3-round cap from plan 026 bounds the fix↔audit cycle.
3. **If the GENUINE finding cannot be auto-resolved** (genuine ambiguity — two
   valid corrections with different tradeoffs, or the fix needs a human scope
   decision), do NOT guess. Surface it as a **blocking finding** and force the
   plan's verdict to `needs-fixes`. A plan with an unresolved GENUINE finding is
   **never silently marked `ready`**.

## Fault tolerance (never stall, never fabricate)

The audit is bounded and tolerant. For a given plan, treat any of these as
**audit-inconclusive**, log it, skip that plan's audit, and let the other plans
proceed:

- codex exits **non-zero** (read `$TMPERR` into the log for diagnostics);
- the Bash call hits the **timeout** (300s elapsed, `timeout: 300000`);
- output is **empty** or **malformed** (no parseable `FINDING:` lines and no
  clean pass statement);
- a finding is missing its **`file:line`** anchor (cannot be acted on).

An `audit-inconclusive` plan is logged as such and contributes **no** findings —
the doctor never fabricates a finding to fill the gap, and never blocks the
whole backlog on one plan's inconclusive audit. Inconclusive is not a blocking
finding; the plan keeps the verdict it earned from the other checks.

## Report-merge format

Merge audit results into the Step 4 report under each plan, alongside the
structural ERRORS/WARNINGS/DEEP/FRAME lines:

```
Plan 042, "Add user avatars"
  AUDIT   [GENUINE] app/views/billing/_plan.erb:1 claim: plan assumes a server-rendered
          _plan partial, but no such partial exists (auto-fixed: Design now renders inline)
  AUDIT   [FORWARD-DEPENDENCY] src/api/avatars.ts:12 endpoint produced by plan 041 (not done) — noted, non-blocking
  AUDIT   audit-inconclusive for plan 047 (codex timed out at 300s) — skipped, other plans proceeded
  AUDIT   [PREMISE-PASS] docs/plans/042-add-user-avatars.md:31 AC4's premise that uploads are already virus-scanned is unsupported (from the run's one no-tension premise pass)
```

`[PREMISE-PASS]` rows come from the once-per-run no-tension pass defined in
`SKILL.md` Step 3.5. They carry the same `FINDING:` shape and are classified
GENUINE / FORWARD-DEPENDENCY by the same rule as any other finding — the pass
changes which plans are audited and what the brief points at, not how a finding
is handled once it exists.

Then feed the results into the loop:

- GENUINE findings that were auto-fixed mark their plan MODIFIED and enter the
  **Step 4b re-validation set** (plan 026), which re-runs the per-modified-plan
  audit slice on the new state.
- An unresolved GENUINE finding forces that plan to `needs-fixes` (blocking).
- FORWARD-DEPENDENCY and audit-inconclusive lines are informational and do not
  block the `ready` verdict.
