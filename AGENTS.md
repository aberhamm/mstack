# mstack Agent Guide

This repository is the source for MStack, a plan-driven autonomous workflow
framework distributed as agent skills.

## Canonical Instructions

- Keep shared project instructions in `AGENTS.md`.
- Keep `CLAUDE.md` as a thin compatibility shim that imports this file with
  `@AGENTS.md`.
- Do not duplicate long-lived workflow rules across both files.
- When adding agent-specific notes, keep the shared rule here and put only the
  agent-specific exception in that agent's file.

## Repository Shape

- `skills/mstack-*` contains the skill source directories.
- `skills/mstack-run/scripts/` contains deterministic shell helpers used by
  multiple skills.
- `skills/mstack-run/references/` contains long-form references loaded on
  demand by `mstack-run`.
- `.codex/agents/` contains Codex custom agent adapters for MStack worker and
  reviewer subagents.
- `docs/plans/` contains this repo's implementation plans; archived completed
  plans live under `docs/plans/archive/`.
- `setup` links MStack skills into a recognised agent skill directory, or the
  configured Skillshare source for a development checkout.

## Skill Routing

When a user request matches an MStack workflow, use the matching skill:

- "create a plan for...", "plan out...", "break this down" ->
  `mstack-plan-multi`
- "validate plans", "check the backlog", "are plans ready" ->
  `mstack-plan-doctor`
- "review the backlog", "reprioritize", "reorder plans", "groom",
  "triage" -> `mstack-backlog`
- "run the plans", "execute the backlog", "start the loop" -> `mstack-run`
- "where are we", "what's next", "backlog status" -> `mstack-status`
- "configure mstack", "change health weights" -> `mstack-config`
- "show learnings", "what patterns" -> `mstack-learned-patterns`
- "stash this", "save for later", "come back to this", "not ready to plan" ->
  `mstack-stash`
- "handoff", "save session state" -> `mstack-handoff`
- "resume from handoff", "load handoff", "pick up where I left off" ->
  `mstack-handoff` in resume mode
- "wrap up the session", "end-of-session review", "harvest this session
  before we close" -> `mstack-wrap-up`. The axis is TERMINAL vs
  CONTINUATION: route here only when the session is *ending* and its context
  should be mined for the repository. Non-examples, because neighbors own
  adjacent phrasing: "wrap this up for now", "come back to this", "save this
  thread for later" -> `mstack-stash` (an unresolved thread, parked);
  "handoff", "save session state", "I'm stepping away" -> `mstack-handoff`
  (continuation, packaged for the next session). "Wrap up" on its own never
  steals a continuation request — check which side of the axis the user is on.

## Not Every Change Needs a Plan

The routing table above says which skill handles a request that *is* MStack
work. It does not say every change is MStack work. **Being in a plan-driven
repo is not a reason to plan every edit.** A plan file plus a doctor pass plus
an execution iteration is real overhead; spending it on a typo fix costs more
than the fix and buries the actual backlog in noise.

**If the change is small enough to just make, make it.** Typos, a one-line
fix, a doc or comment correction, a config value, a rename, a missing test,
tightening prose in a skill — do the work and say what you did. Do not offer
to write a plan first, and do not scaffold one "for the record."

Reach for a plan only when at least one of these is true:

- The work splits into steps that must land in a specific order.
- It touches a seam other work depends on, or carries real rollback risk.
- It genuinely needs an eng/design/CEO review before implementation.
- The user wants it *queued* for autonomous execution rather than done now.

None of those true? It is an errand, not a plan. Just do it.

**This matters most right after a plan or a goal completes.** That moment —
`[mstack] Done.`, or a plan just tagged — is when the pull toward "I'll add a
plan for that" is strongest and least justified. Follow-ups surfacing there
(polish the wording, rename the helper, fix the small thing review turned up,
delete the scaffolding) are follow-ups. Make them directly, commit them
normally, and mention them in the wrap. Queue a plan only if the follow-up is
itself plan-sized by the test above.

When you are genuinely unsure, prefer doing the small thing and saying "this
seemed too small for a plan — say the word and I'll queue one instead." That
is cheaper to reverse than an unwanted plan file is to retire.

## Review Records and the Completion Gate

A plan flagged for review must not be markable done/cleared until that review
has actually been performed and RECORDED. The deterministic mechanism lives in
`skills/mstack-run/scripts/review-gate.sh` (plan 034). It is fail-closed: any
ambiguity resolves to "required" / "not completable", never open.

**End-to-end invariant:** authoring declares required reviews
(`review-required`, stamped once and never shrunk) → only the named review
skills record verdicts (`review-gate.sh record`, plan 035) → completion
refuses to proceed until every required verdict is recorded passing
(`assert-completable`, plan 036) → a recorded `reviewed`/`reviews`/
`review-required` state can never be silently downgraded
(`assert-no-downgrade`, plans 034/036). Each link is enforced by a distinct
mechanism; breaking any one link breaks the invariant.

`mstack-run` Step 7a runs `assert-completable "$NEXT"` as the very first
action of its success path — before the `status: done` write, the archive,
and the `mstack/plan-${PLAN_ID}-done` tag — and aborts the whole sequence on
a nonzero exit: it sets `status: blocked` and `needs-review:` to the
still-open type(s) (re-using `pick-next.sh`'s existing skip-on-non-`none`
mechanism, not a new one, so the picker doesn't loop on the same plan) and
commits only the plan file. `needs-review` can carry `code` here — an
unresolved code-review finding has no automated remediation path the way
eng/design/ceo do via `mstack-plan-doctor` Step 5, so it needs a human to
re-run `mstack-code-review` or fix and re-record. It also runs
`assert-no-downgrade "$NEXT"` before writing `reviewed`/`review-required`/
`reviews`; at Step 7a this is normally inert (`reviewed: false` is a fresh
add on a plan's first completion, not a downgrade) but the same call is what
refuses a later out-of-band `reviewed: true → false` edit. Fixture/smoke
plans (e.g. `bin/mstack-codex-smoke`'s `001-create-hello`) are authored with
`needs-review: none` and no `review-required`, so they have an empty
required set and the gate is naturally a no-op for them — no path-based
exemption exists or is needed. `mstack-status` and `mstack-plan-doctor`
independently re-check `review-gate.sh` per pending/blocked plan with a
declared requirement and surface an open gate as a blocked/gate-open state,
so it's visible before a completion attempt, not just at completion time.

**This is anti-forgetfulness, not anti-adversary.** Step 7a only stops an
agent that runs the honest completion path. An agent that skips Step 7a and
hand-writes `status: done` plus `git tag` bypasses this check
entirely — wiring the assertion into Step 7a does not, by itself, make
completion unbypassable. That hole is closed at the write layer by the
plan-038 git hook (`.githooks/pre-commit` + `pre-push`, installed via
`core.hooksPath`), which rejects such a commit/tag regardless of how it was
produced, with `review-gate.sh audit` as the retroactive backstop. Treat
034/035/036 as the honest-path layer and 038 as the enforcement layer; see
**Layered Enforcement Model (plan 038)** below for the full four-layer model
and its honest residual.

Three distinct frontmatter fields, do not conflate them:

- `needs-review:` — MUTABLE remaining-work tracker (`none | eng | design | ceo`
  and comma combinations). The picker skips plans whose value is non-`none`;
  reviewers flip it as work completes.
- `review-required:` — IMMUTABLE declared gate list (subset of
  `eng,design,ceo,code`), stamped once at authoring and NEVER cleared or shrunk.
  It lists the review types that must be recorded passing before completion.
- `reviews:` — the SINGLE SOURCE OF TRUTH the gate trusts, a block of compact
  one-line records (values never contain spaces):

  ```
  reviews:
    - type=eng verdict=approved date=2026-07-04 by=agent
    - type=code verdict=pass date=2026-07-04 by=mstack-code-review
  ```

  `type ∈ eng|design|ceo|code`; `verdict ∈ approved|changes-requested|pass|fail`.
  eng/design/ceo clear the gate with `approved`; `code` clears with `pass`. A
  `code` review records `fail` when any critical/high finding remains unfixed
  after review (mapped from the `findings_*` counts by
  `code_verdict_from_findings` in `lib.sh`), else `pass`. An absent `code`
  record is an OPEN gate. The `.mstack/reviews/plan-<id>.json` file is a derived,
  NON-authoritative cache; the gate never trusts it.

Fail-closed rules that must not be softened:

- ABSENT `review-required` ≠ empty required set. When the field is absent the
  gate derives the required set from `needs-review` (any non-`none` tag). Legacy
  plans without the field are non-completable until backfilled
  (`review-gate.sh backfill <plan> | --all`).
- `assert-completable <plan>` exits 0 only if every required review has a passing
  record; missing/garbled records are non-completable.
- `assert-no-downgrade <plan>` diffs the working tree against committed `HEAD`
  and fails on `reviewed: true→false`, a removed/weakened `reviews:` entry, or a
  shrunk/emptied `review-required`. A plan not yet in `HEAD` has no baseline, so
  it passes (nothing to downgrade from).

`review-gate.sh` exit codes: `23` = not completable, `24` = downgrade detected,
`25` = approved but uncommitted, `26` = enforcement hook missing/stale
(`assert-hook-installed`), `27` = retroactive audit found an offender
(`audit`) — all defined in `lib.sh`; do not collide with pick-next 10-19,
seam-check 20, resolve_plan_ref 21-22.

## Layered Enforcement Model (plan 038)

Completion enforcement is a **defense in depth of four distinct layers**, each
firing at a different moment and independent of the others. Do not conflate
them or treat any single one as the whole story:

1. **Picker = convenience.** `pick-next.sh` skips `needs-review != none`
   plans so the honest loop rarely reaches a completion it cannot finish. This
   is ergonomics, not enforcement — it is trivially bypassed by running a plan
   outside the picker.
2. **Step 7a gate = honest-path check.** `mstack-run` Step 7a runs
   `assert-completable` / `assert-no-downgrade` before writing `status: done`,
   archiving, and tagging. This stops an agent that runs the honest completion
   path but does **nothing** against an agent that skips Step 7a and
   hand-writes `status: done` + `git tag`. It is anti-forgetfulness, not
   anti-adversary.
3. **Git hook = write-time barrier.** A tracked `.githooks/` (installed by
   `mstack-init` / `setup` via `git config core.hooksPath .githooks`) provides
   `pre-commit` (rejects a commit whose STAGED plan content transitions to
   `done` while `assert-completable` fails, or weakens a recorded review state)
   and `pre-push` (rejects publishing a `mstack/plan-*-done` tag for a
   non-completable plan). The hook fires **regardless of how the commit was
   produced** — it does not depend on the agent choosing to run Step 7a. The
   thin hook shims delegate to `review-gate.sh hook-pre-commit` /
   `hook-pre-push`, resolving the installed skill dir so they work in any
   consumer repo. If the hook cannot locate `review-gate.sh` it fails **open**
   for ordinary commits (never bricks unrelated work) but fails **closed** on a
   detected plan done-transition (refuses it, pointing at the reinstall).
   `mstack-run` and `mstack-plan-doctor` run `assert-hook-installed` at startup
   and refuse to operate if the hook was removed or edited.
4. **Audit = retroactive backstop.** `review-gate.sh audit` (surfaced by
   `mstack-status` and `mstack-plan-doctor`) scans every `done`/archived plan
   and flags any whose `review-required` types lack a passing record. This is
   what catches the two ways layer 3 can be evaded: `git commit --no-verify`
   (which skips the hook) and out-of-band edits.

**Honest residual — state it plainly, do not claim more.** Git hooks are
local-only (not cloned with the repo) and `--no-verify`-bypassable, and any
actor with shell access can delete the hook or suppress the audit. So this
model makes completion enforcement **deterrent + detectable**, NOT
cryptographically unbypassable — that is impossible when every actor is the
same agent with shell access. The audit is precisely what converts "bypassable"
into "a bypass leaves an evidence trail the next audit/status/doctor run
surfaces." An actor who both `--no-verify`s a completion AND suppresses the
audit is explicitly out of achievable scope. The value here is that routing
around the gate is no longer silent or free.

## Approved Plans Are Always Committed (plan 037)

Once a plan has a recorded review verdict, that verdict — and the plan file
carrying it — must be persisted to git; it cannot be left to live only in the
working tree. **"Approved" here means "has >=1 recorded `reviews:` entry"**
(any type, any verdict, including `changes-requested` — a recorded verdict of
any kind is still a verdict that must not be lost), **not** "gate reads
cleared". This is deliberately a lower bar than `assert-completable`'s
"every required review passes": a plan can be far from completable (e.g. one
of three required reviews recorded, or the one recorded review came back
`changes-requested`) and still be bound by this invariant, because the thing
being protected is the review record itself, not the completion decision.

The deterministic check is `review-gate.sh assert-committed <plan>`
(`skills/mstack-run/scripts/review-gate.sh`): exit 0 if the plan has no
recorded `reviews:` entry at all (EXEMPT — authoring-only / review-pending
plans are allowed to sit dirty by design, since the invariant binds only once
a verdict is recorded), or if it has one and the plan file is clean vs `HEAD`.
Exit `EXIT_GATE_NOT_COMMITTED` (`25`) if it has a recorded entry and the plan
file is dirty (modified or untracked). This is a **single-path** check on the
plan file only: `.mstack/reviews/*.json` is gitignored (`.gitignore:6`) and
can never be committed or diffed against `HEAD`, so it is never part of this
check — the frontmatter `reviews:` block is the only committable record.

Commit sites (the invariant is enforced at the choke point, not by scanning
after the fact):

- **`mstack-plan-doctor` Step 5** commits the plan file immediately after
  `review-gate.sh record` and the `needs-review`/`status` bookkeeping edit,
  on both the approve path (`chore(plan NNN): approve (<type>)`) and the
  changes-requested path (`chore(plan NNN): review changes-requested
  (<type>)`) — a recorded verdict of either kind must not sit uncommitted.
  Explicit file list, no push.
- **`mstack-run`** runs `assert-committed "$NEXT"` immediately before
  delegating to the implementation agent (execution start, not cached from
  earlier in the run). In the normal case this is a no-op, since the
  approval-commit already landed at plan-doctor time before the plan was
  ever picked up; it exists to catch a skipped/reverted approval commit or a
  post-approval hand-edit. On failure it attempts to auto-heal by committing
  the plan file, then re-checks; if still failing it blocks the plan
  (`status: blocked`, `needs-review: eng`) rather than executing against a
  dirty approval.
- **`mstack-status`**, **`mstack-backlog`**, and **`mstack-plan-doctor`**
  each independently audit every `pending`/`blocked`/`in-progress` plan with
  a cheap `reviews:`-presence pre-filter, then `assert-committed` for
  flagged plans, surfacing any approved-but-uncommitted plan as a warning —
  this heals pre-existing dirty approvals from a prior session (crash,
  stash, hand-edit), not just ones a given run just recorded. `mstack-status`
  is read-only and only reports; `mstack-backlog`/`mstack-plan-doctor` may
  offer to commit the healing fix.

**TOCTOU caveat:** `assert-committed` is point-in-time. A `git checkout` or
stash after it passes could re-dirty the approval before execution actually
starts. On solo-main this is low risk; plan 038's retroactive audit is the
backstop for drift that happens outside any single run.

This is the approval-stage analogue of the completion-commit invariant
(`mstack-run` Step 7a + plan 036): authored (may be dirty, review-pending) →
approved + committed (this invariant) → executed → completed + committed +
tagged.

## Completion Requires the Work Committed (plan 039)

**Done ⇒ the declared work product is committed; a dirty plan-attributable tree
is an invalid terminal state.** Plan 036 makes completion fail closed on an open
review gate and plan 037 commits the approved plan file — but neither guarantees
the agent's actual code changes are committed when the plan is tagged done.
"Done with a dirty/uncommitted working tree" must not be a valid outcome, and
"the agent should remember to commit" is exactly the convention this enforcement
family removes.

The rule is `(current porcelain set) minus plan-start baseline == empty` at
completion, with BOTH sides produced by the single `lib.sh porcelain_paths`
normalizer (`git status --porcelain -uall -z` — rename/space/quote-safe, and
`-uall` so new work inside a pre-existing untracked directory is not an
invisible false negative). The baseline is `PRE_DIRTY`, captured at plan start
and **persisted** to a gitignored `.mstack/pre-dirty-<id>.txt` (shell state does
not survive to Step 7a, which runs the check in a separate process). Subtracting
the baseline distinguishes "the plan left work uncommitted" (block) from "the
user had unrelated edits open before the run" (allow, never force-committed) —
except a file the plan itself touched that was also pre-dirty
(`MODIFIED ∩ PRE_DIRTY`), which stays committed-together per existing Step 7a
behavior.

- `review-gate.sh assert-work-committed <plan>` exits `EXIT_GATE_WORK_UNCOMMITTED`
  (`28`) on any plan-attributable dirt, and **fails closed** on a missing
  baseline file or an unreadable git status (cannot verify ⇒ not completable).
  It never auto-`git add`s — committing declared work is Step 7a's job.
- The `---MSTACK-RESULT---` contract carries a `DELETED` list alongside
  `MODIFIED`/`CREATED` so deletions/renames are actually committable; without it
  a `D`/`R` entry would sit uncommitted and block every deletion-bearing plan
  forever. The **worker keeps its never-commit contract** — this commit-on-
  completion duty lives with the orchestrator (Step 7a), after the gate passes,
  so the health gate can still roll back on failure.
- Step 7a runs `assert-work-committed` **after** the hash-backfill
  `git commit --amend` and **before** the archive `git mv`, so it inspects the
  post-work committed state; on failure it HALTS and reports the stray paths (no
  auto-`git add`, no `mstack/plan-*-done` tag).

**Honest residual — the Step 7a check is the real enforcement.** A `pre-commit`
hook *cannot* detect uncommitted work (by definition it is not in the commit),
and no durable artifact records "the tree was dirty at completion," so plan
038's retroactive `audit` **cannot** enforce this rule — do not claim it does.
The only added non-optional touch is an optional, clearly-caveated `pre-push`
guard in 038's hook that rejects pushing a `mstack/plan-*-done` tag while
`git status` is dirty — a best-effort deterrent that is TOCTOU and
`--no-verify`-bypassable, not a proof. So the honest-path Step 7a
`assert-work-committed` is the enforcement; the pre-push guard is a thin extra
net; and there is deliberately no pre-commit or audit claim for uncommitted
work.

**Only the named review skills write review records or clear gates** (plan
035). `plan-eng-review` / `plan-design-review` / `plan-ceo-review`
(orchestrated by `mstack-plan-doctor`'s Step 5) record `eng`/`design`/`ceo`
verdicts; `mstack-code-review` records the `code` verdict. No other actor —
not a worker/implementing agent, not `mstack-run` itself — may invoke
`review-gate.sh record`, edit `review-required` or `reviews` to clear or
weaken a gate, mark a needs-review plan `done`, or run a needs-review plan
outside the picker. The observed anti-pattern this forbids explicitly: an
agent offering to self-clear `needs-review: eng`, or to "say go and I'll
proceed outside the picker" — both are forbidden; the remediation is always
to run the named review skill. Adding or raising a gate (setting
`needs-review: eng` on an incomplete spec or stale seam) stays allowed for
any actor; only clearing/weakening one is restricted.

## The Health Gate Never Silently No-Ops (plan 043)

**A health gate that did not run is not a health gate that passed.** Through
plan 039 the gate in this very repo had never scored a single plan: the `shell`
detector globbed `-maxdepth 3` while mstack keeps its scripts at depth 4, found
zero tools, and `die`d — and the worker, given exactly two branches (`PASS` →
continue, `FAIL`/`REGRESSED` → investigate) and no branch at all for "the
command crashed", improvised `HEALTH_VERDICT: SKIP` (not even a legal value)
and the orchestrator accepted the plan as passing.

The generalizable defect was the missing branch, not the glob. Three rules
follow, and the third is the one that actually enforces anything:

1. **Legal verdicts are a closed set:** `PASS`, `FAIL`, `REGRESSED`,
   `NO-TOOLS`, `NONE-DECLARED`. `SKIP` is not a value. A crashed gate (nonzero
   exit, no parseable `VERDICT`) is a HARD FAILURE with reason
   `health-gate-unavailable` — never a skip, never a pass.
2. **Detection covers the whole repo surface, tracked AND untracked.** Workers
   never commit before the gate runs, so a `.sh` file a plan just created is
   untracked; linting only tracked files would skip exactly the code under
   test. The surface is git's own view of the working tree (`ls-files` ∪
   `ls-files --others --exclude-standard`), which inherits `.gitignore`
   semantics for the prune policy for free. There is no depth cap and no count
   cap — a cap reports PASS over scripts that were never linted, which is the
   same bug class in miniature.
3. **The orchestrator parses the health result; it does not trust it.**
   `mstack-run` Step 7a's first action is
   `scripts/result-gate.sh assert-health-result`, which rejects (exit `30`) any
   `STATUS: pass` block whose `HEALTH_VERDICT` is missing, unparseable, or
   anything other than `PASS`/`NONE-DECLARED`, or whose `HEALTH_COMPOSITE` is
   not a number (`n/a` only alongside `NONE-DECLARED`). The bug was an LLM
   improvising around an unhandled state; fixing it with more prose aimed at
   the LLM is the same material that already failed. The prose branch in
   `references/subagent-prompt.md` is the honest-path layer; this parse is the
   enforcement.

**Zero-tools policy: BLOCK UNLESS DECLARED.** Zero tools across ALL categories
(not "one empty category" — a JS repo with typecheck+lint+test and no `.sh`
files is fine) makes a plan **not completable**: `health-check.sh run` emits
`VERDICT:NO-TOOLS` and exits `EXIT_HEALTH_NO_TOOLS` (31). The single escape
hatch is an explicit declaration — a `- none:` entry in the `## Health Stack`
section of a **tracked** guidance file (`AGENTS.md`/`CLAUDE.md`):

```markdown
## Health Stack

- none: no automated health tools in this repo
```

which yields `VERDICT:NONE-DECLARED`, exit 0, completable.

The declaration MUST live in tracked project guidance and is deliberately NOT
readable from `.mstack/config.json` — `.mstack/` is gitignored, so a declaration
there would be invisible to review, per-checkout, and gone on a fresh clone,
making "explicit declaration" mean "whatever happened on this machine". That is
the same invisible-state class this rule abolishes.

**This mirrors the review-gate doctrine already in force** — "ABSENT
`review-required` ≠ empty required set... non-completable until backfilled".
Config absence means UNDECLARED, not empty, and undeclared fails closed. One
rule, not two.

## Permission Not To Block Is Not Instruction Not To Ask (plan 045)

`review-gate.sh assert-committed` exempts a plan with no recorded `reviews:`
entry: it "may sit dirty". That sentence grants the **completion gate**
permission **not to block**. `mstack-wrap-up` read it as an instruction **not to
mention**, and excluded every `reviews:`-less plan file from its git-hygiene
question. A fresh scaffold and a 419-line fully-authored plan are
indistinguishable under that test — both have no `reviews:` entry — so a whole
session's research sat untracked at close and the tool said nothing.

Two rules follow, and they generalize past this one skill:

1. **A non-blocking rule never implies silence.** When one layer is permitted
   not to gate on a state, no other layer inherits permission to hide it.
   Gating and reporting are separate decisions; deriving the second from the
   first is a category error, not an optimization.
2. **Discriminate the states that look alike, deterministically.**
   `review-gate.sh plan-authored <plan>` answers scaffold-vs-authored by
   checking whether the instructional sentinels **derived at runtime from
   `plan-template.md`** are still intact — one source of truth, no hardcoded
   copy of the template's prose to drift. It reads no review state and writes
   nothing.

**The polarity is inverted on purpose; do not "fix" it.** `plan-authored` exits
`0` for AUTHORED (surface it) and `EXIT_PLAN_SCAFFOLD` (`32`) for a pristine
scaffold. Only that exact code buys silence — a missing template, fewer than 3
extractable sentinels, an unresolvable ref, or an outright crash all land on
"authored", i.e. ask. This mirrors the fail-closed doctrine above with the cost
asymmetry pointed the other way: the expensive outcome here is not a false
block, it is a false silence. Asking costs one button; silence costs a session's
only artifact.

Wrap-up's verdict stays **non-blocking in all three tiers** (scaffold →
silent; authored + unreviewed → surfaced in the git-hygiene question; approved +
dirty → a plan-037 finding). This changed what is *asked*, never what is
*gated*.

### A fail-safe default hides a dead feature

The fix above shipped **dead on arrival** and looked fine for a day.
`review-gate.sh` was committed mode `100644`, wrap-up located it with an
`[ -x ]` test, `REVIEW_GATE` resolved empty, and `plan-authored` never executed
once. Nothing errored — because the fail-open-to-"authored" branch, designed
above as the *safe* direction, produces output indistinguishable from the
discriminator running and returning "authored".

The general rule, and it cuts against the instinct that a safe default is
free: **a fail-safe default is a place where dead code hides.** When the
degraded path and the working path look the same from outside, "no errors" is
evidence of nothing. So a component with a fail-safe default owes two extra
things:

- **Say which mode it is in.** Wrap-up prints `REVIEW_GATE=<path|none>`. A
  degraded run must be legible as degraded, not merely correct-looking.
- **Do not let a resolution test depend on a bit nothing verifies.** A helper
  invoked as `bash "$HELPER"` needs `-r`, not `-x`. The mode is asserted
  separately by `script-mode-smoke.sh`; resolution does not rely on it either
  way, so neither mechanism is a single point of silent failure.

## An Uncited Factual Premise Is a Finding (Rule 1, plan 088)

**The pipeline verified what a plan CITED and exempted what it ASSERTED, and
that asymmetry is backwards.** In the cctrl 051-053 batch, three plans cleared
an eng review plus a cross-model pass — 18 findings folded in, verdict "ENG
CLEARED" — while carrying two P1 defects fatal to the first real run. Both were
the batch's only uncited premises about existing code ("the picker is a modal,
so `_session_rich_state` should report `blocked-dialog`" cited nothing), and
every *cited* claim in the same plans (line refs, JSON key counts, measured
timings) had been checked. Decorating a claim with a citation ATTRACTED
verification; omitting one BOUGHT EXEMPTION.

The mechanism is `skills/mstack-run/scripts/premise-lint.sh lint <plan>`, run
per plan by `mstack-plan-doctor` Step 3.9. It classifies each acceptance
criterion in `## Requirements` into exactly one of four classes:

- **CITED-UNRESOLVED** — cites a `snake_case`/`camelCase` symbol or a
  repo-relative path that resolves nowhere in the working tree and that no plan
  declares it will create. Exit `EXIT_PREMISE_UNCITED` (37).
- **UNCITED** — carries a premise signal about existing code and cites nothing.
- **CITED-OK** — every citation resolves, or is a declared forward reference.
- **NO-PREMISE** — asserts nothing about existing code.

**The calibration is the design, and it splits on PROVABILITY.** This repo has
already shipped an over-blocking lint once — `verify-lint.sh` conflated PENDING
with BROKEN and flagged six well-formed plans as dead. So CITED-UNRESOLVED
blocks *in the script* (it is provable from the repo), while UNCITED never sets
the exit code: the script reports it and **plan-doctor's Step 4b** makes it
blocking only after its own auto-fix round fails, the same discipline Step 3.5
applies to a GENUINE adversarial-audit finding. Resolving an UNCITED means
adding the real citation or rewriting the AC to assert nothing about existing
code — deleting the signal word is not a resolution.

Two things the search surface must keep, because dropping either kills the
check silently:

- The surface is git's view of the working tree (`ls-files` ∪ `ls-files
  --others --exclude-standard`), tracked AND untracked — plan 043's rule, same
  reason: a plan authored in the session that created a file must see it.
- **Symbol content search EXCLUDES `docs/plans/` (and its `archive/`).** The
  symbol is being read out of a plan file, so a repo-wide content search finds
  it in the very plan under lint and *every* citation self-resolves —
  CITED-UNRESOLVED becomes unreachable by construction, which is the plan-045
  failure mode where a check that cannot fail looks exactly like one that
  passes. Path citations keep the full surface, plan files included: a path
  that exists is evidence regardless of directory. `premise-lint-smoke.sh` case
  2 fails if the exclusion is dropped.

**NOT EVERY BACKTICKED TOKEN IS A CITATION, and the evidence for that was
measured after shipping, not designed in.** A sweep of all 14 pending plans on
this repo's live backlog fired the blocking class 4 times, and **all four were
false positives — a 100% false-positive rate**, the same profile the Rule 3
tiering was built to remove. Nothing was cited wrong in any of them; the tokens
had never been citations:

- plan 068 AC3 flagged `if/fi` — a shell keyword pair named in prose.
- plan 068 AC4 flagged `tests/test_x.py` and `other/tests/test_x.py` —
  illustrative paths invented to EXPLAIN a substring-matching bug. Neither
  `tests/` nor `other/` exists at this repo's root.
- plan 068 AC5 flagged `${var#"$root"/}` — a shell expression being PROPOSED as
  the fix.
- plan 055 AC2 flagged `$d/marker` — part of an injection-test payload in a
  temp-repo fixture.

The live consequence was that plans 055 and 068 (11 ACs) would have been blocked
by Step 3.9 for citing nothing wrong. Three exclusions now run before a token is
eligible to be a citation at all:

- **SHELL SYNTAX** — a token carrying `${`, `$(`, `#`, `|`, `&`, `;`, a quote, or
  a bracket. That is code being PROPOSED or DEMONSTRATED, not a repo identifier
  being CITED, and it cannot resolve against a working tree by construction.
- **SHELL KEYWORDS** — `if`, `fi`, `then`, `else`, `elif`, `do`, `done`, `case`,
  `esac`, `while`, `until`, `for`, `in`, and the slash-joined pairs prose writes
  them in. A token qualifies only when EVERY `/`-segment is a keyword, so a real
  path under a directory named `case` stays citable.
- **IMPLAUSIBLE PATHS** — a *multi-segment* path whose FIRST segment is not a
  real top-level entry of this repo. The allowed set is derived at runtime in
  `_build_surfaces` (working-tree first segments ∪ `ls -A` of the root); a
  hardcoded list would rot the moment a directory is added, and rot silently,
  since its failure mode is a new false positive.

**Two calibration details that are load-bearing, not incidental.** Plausibility
is asked ONLY of a path that already failed to resolve — plans here routinely
cite a real file by its tail (`scripts/lib.sh`, `mstack-wrap-up/SKILL.md`) and
filtering before resolution would demote every one from CITED-OK for no gain.
And a token with NO slash is always plausible, because its only segment is the
filename: testing it against the top-level set would demand that every bare
filename citation (`checkpoint.sh`, `health-reach.sh`) sit at the repo root.

**The measured effect, both directions.** Across the same 14 plans / 92 ACs:
cited-unresolved 4 → 0, cited-ok 38 → 42, and **UNCITED unchanged at 6,
NO-PREMISE unchanged at 44** — the fix moved exactly the four false positives
and nothing else. The blocking class is NOT dead: a nonexistent file under a
real top-level entry (`skills/mstack-run/scripts/nope.sh`) and a snake_case
symbol that exists nowhere both still exit 37, asserted as a positive control in
`premise-lint-smoke.sh` case 8b. Case 8 pins all four real false positives using
their VERBATIM strings, so a reworded approximation cannot let the regression
back in.

Forward references are not defects, and the two exemptions are NOT one rule:
the **self** exemption (this plan's own `**Files expected to change:**`) is new
to this lint, and the **ancestor** exemption (a not-yet-`done` `blocked-by`
ancestor's declared output) is the rule Step 3.5's classifier already states.
Both yield CITED-OK.

**Honest residual — state it, do not oversell it.** The UNCITED detector is a
WORD LIST (`should`, `presumably`, `by construction`, `assumes`, `already`,
`existing`, `current`, `currently`, `since`, `because`, `so that it reports`,
`will report`) matched against the AC with code spans blanked out. It **both
over- and under-matches**: it flags narrative prose that asserts nothing, and it
misses any premise phrased without one of those words ("the picker returns the
pane title" is a load-bearing assertion with no signal at all). That is exactly
why UNCITED reports instead of blocking, and why the reviewer checklist in Step
5 exists — the lint aims attention, it does not replace judgment. Tune the list
in place; do not add a second detection mechanism beside it.

### The `rules.*` toggle namespace

Plan-stage lints are individually disableable through a two-level key in
`.mstack/config.json`, read by `rule_enabled <key>` in `lib.sh`:

```bash
bash skills/mstack-run/scripts/config.sh set rules.citation_or_finding false
```

Known keys: `citation_or_finding` (Rule 1, plan 088), `tui_fixture` (089),
`premise_brief` (090), `amendment_repass` (091). `config.sh set` rejects an
unknown key and a non-boolean value, because a typo would otherwise be a rule
the user believes they configured and did not.

Two properties, both load-bearing:

- **Two levels, not three.** `rules.<key>`, never `review.rules.<key>`.
  `json_get`'s awk fallback handles at most 2 levels, so a 3-level key would be
  unreadable wherever `jq` is missing — and since a degraded read must resolve
  to ENABLED, a 3-level key would make the disable silently inoperable on those
  machines.
- **Fails OPEN, and every consumer prints its mode.** Absence, an empty `rules`
  object, an unreadable or garbled config, and a degraded `json_get` fallback
  ALL mean ENABLED; only a value of exactly `false` disables. This is plan 045's
  rule applied to configuration — a lint that silently turns itself off is
  indistinguishable from one that ran and found nothing, so "no findings" would
  become evidence of nothing. Consumers announce
  `[mstack] rule <key>: enabled | disabled (config)` via `rule_mode_line`, so a
  disabled run is legible as disabled rather than merely correct-looking.

Flipping one key disables exactly one rule; reverting one rule touches one
script, one doctor step, and one smoke suite. `rule-toggle-smoke.sh` asserts
both the polarity and the independence.

## A Pane-Dependent Plan Must Attach a Real Capture (Rule 3, plan 089)

**A plan whose logic keys on terminal screen content is writing a parser against
an undocumented, unversioned external interface.** Nobody writes a parser for a
third-party API from memory — they save a real response and code against it. The
capture is that saved response. The cctrl track record is unambiguous: every
shipped detector bug there (ASCII `>` vs the real prompt glyph, an "Allow
command" string matching no real modal, the 2026-08-05 picker premise) lived in
the gap between what an author *remembered* a screen saying and what it actually
says. The real string was sitting in a manifest the whole time.

The mechanism is `skills/mstack-run/scripts/fixture-lint.sh lint <plan>`, run
per plan by `mstack-plan-doctor` Step 3.10. It emits exactly ONE verdict line
whose **first whitespace-delimited token** is one of exactly four verdicts:

- **FIXTURE-MISSING** — pane vocabulary in Requirements/Design/Tasks (see the
  two tiers below) and either no capture declared under a `fixtures/` path, or
  one declared that is not in the working tree. Exit
  `EXIT_TUI_FIXTURE_MISSING` (38).
- **FIXTURE-UNDATED** — the capture exists, its provenance sidecar does not.
- **FIXTURE-OK** — capture present with provenance.
- **NOT-APPLICABLE** — no pane vocabulary, or a declared exemption.

**Everything after the token is free-form detail** (the matched keyword, the
quoted line, a path). Consumers parse token one and ignore the rest, so detail
can be improved forever and a fifth verdict can only ever enter through the
token position. The verdict line is unconditional, including for
NOT-APPLICABLE: a silent run is indistinguishable from a lint that never
executed — plan 045's rule, applied here rather than rediscovered.

**The calibration departs from plans 046/047 on purpose; do not "simplify" it
back.** `verify-lint.sh` (33) and `health-reach.sh` (34) defer on a plan's
*output* — a check or a test file it has not written yet — because blocking
pre-implementation work is how a lint earns a permanent bypass. Rule 3 blocks on
a declared-but-absent capture anyway, because **a capture is an input, not an
output**: it is evidence the author had to hold *before* writing the detector.
Rule 3's text is "must attach", present tense. "I'll capture the pane later" is
precisely the plan that writes its detector from memory first, so deferring on it
would defeat the rule entirely. Missing *provenance* is the one reported-only
case, because a strict provenance parse would reject real captures for cosmetic
reasons.

**Provenance is a SIDECAR, never a header inside the capture.** Rule 3 requires
an unedited `tmux capture-pane -p` dump, and prepending a header edits it. For a
capture at `<path>`, provenance lives at `<path>.meta`:

```
capture-date: 2026-08-05
agent-cli-version: claude-code 2.1.4
```

The sidecar is what makes "unedited dump" and "carries capture date and CLI
version" simultaneously satisfiable. The parse is deliberately weak — both keys
present, `capture-date` shaped `YYYY-MM-DD`.

**Companion repo-side convention: re-capture on agent CLI upgrades.** A pane
fixture is a snapshot of one version of one TUI. When the agent CLI that draws
that screen is upgraded, every committed capture is provisionally stale and the
detectors keyed to it are unverified until re-captured. `agent-cli-version` in
the sidecar exists to make that answerable by reading, rather than by rerunning
the tool and comparing by eye. Nothing enforces the re-capture; the field is what
makes the staleness visible.

**The exemption is a declaration, not a heuristic.** A keyword list will match
prose that discusses pane-scraping without doing any. The escape is one
frontmatter line in the tracked plan file:

```yaml
tui-fixture: n/a  # <why this plan scrapes no pane>
```

The reason is **required** — a bare `tui-fixture: n/a` is not honored and the
plan is linted normally. It is deliberately NOT readable from
`.mstack/config.json`: that directory is gitignored, so a declaration there would
be per-checkout, invisible to review, and gone on a fresh clone. Same reasoning,
verbatim, as the health gate's `- none:` rule above. Plan 089 itself carries the
declaration and is the live test of that path.

**The vocabulary has TWO TIERS, and the split is calibration, not tidiness.**

- **STRONG** — `capture-pane`, `send-keys`, `tmux`, `pane shows`, `pane
  content`, `screen scrape`, `screen-scrape`. These name the *mechanism* of
  reading a screen and are unambiguous in any repo. Each matches on its own.
- **WEAK** — `modal`, `picker`. These name a screen *artifact* and are ambiguous
  across domains. They match **only** when at least one STRONG keyword is also
  present in the plan.

**The evidence for the split was measured, not guessed.** The un-tiered list,
with `modal` and `picker` firing alone, hit 9 of 41 live plans in this repo and
**every one was a false positive**: "picker" here means `pick-next.sh`, the plan
picker, which draws no screen at all — and six of the nine were pending plans
the doctor would have blocked. A check whose only observed firings are all wrong
is precisely the profile that earns a permanent bypass, and a bypassed check
covers nothing. With the tiering, the active backlog is 41 of 41
`NOT-APPLICABLE` and the only firing anywhere is one archived, `done` plan about
cctrl tmux *session* management (`030`) — not linted by the doctor, and
tmux-adjacent enough that the strong match there is defensible.

**Real pane work loses no coverage**, which is what makes the tiering safe
rather than merely quieter: a plan that scrapes a pane has to say how it reads
the pane, so it says `tmux` or `capture-pane` by necessity. The cctrl picker plan
that motivated Rule 3 says both, repeatedly. The weak tier still earns its keep —
once the strong gate has opened, "the modal" and "the picker" are exactly the
lines worth quoting back to the architect, so a weak keyword may still be the one
the finding names.

**Honest residual — a keyword list both over- and under-matches.** The tiering
removed the live over-match; it did not repeal the class. Both directions remain
possible in principle: a plan can discuss `tmux` without scraping anything (the
declared exemption is the answer), and a plan can key on screen content with no
keyword at all ("when the footer reads Waiting, resume" is a load-bearing screen
premise with zero signal). No keyword list closes the second half, which is why
the lint stays narrow about what it claims: it cannot verify that a capture
matches reality — nothing can, from inside a plan-doctor run — it only refuses to
let a pane-dependent plan proceed with *no* captured evidence at all.

Tune the tiers in place, adding each word to the tier matching its ambiguity; do
not add a second detection mechanism beside them, and do not resolve a finding by
deleting the keyword from the prose (that hides the dependency instead of
evidencing it).

## Independence of Style Is Not Independence of Attention (Rule 4, plan 090)

**A unanimous cross-model clearance is evidence about the BRIEF, not about the
plan.** In the cctrl 051-053 batch the outside voice was asked to do a sharper
version of the primary reviewer's job, and it did: the review report reads
"CROSS-MODEL: No tension — Codex sharpened two review findings rather than
disputing them." Two P1 defects shipped anyway. The third-model audit that did
catch both was not a better model — it was *briefed adversarially*. Two models
handed the same framing agree because they are reading the same way, and the
agreement is then cited as confirmation. That is the escape route Rule 4 closes,
and closing it costs nothing per run: the differentiator is the mandate, and the
mandate is free.

The mandate is the same in all four places it ships, adapted to what each one
reads:

- `skills/mstack-plan-doctor/references/adversarial-audit.md` — the codex brief
  now says **do not sharpen or extend the primary reviewer's findings** and
  attacks premises in a fixed priority order: (a) the plan's uncited factual
  claims, injected verbatim as `UNCITED PREMISES (attack these first):` from
  Rule 1's `UNCITED` lines; (b) every "should / presumably / by construction /
  obviously" sentence; (c) any premise whose failure invalidates a whole
  acceptance criterion rather than a detail.
- `skills/mstack-plan-doctor/SKILL.md` — Step 3.5's no-tension trigger and Step
  5's review-invocation mandate line.
- `skills/mstack-plan-multi/references/structural-critique.md` — "both clear"
  across a breakdown buys one premise-directed re-ask, not a proceed.
- `skills/mstack-code-review/SKILL.md` — the same framing adapted to code:
  attack what the diff *assumes about the code around it*, not what it does.

**The `UNCITED PREMISES` section is omitted entirely when empty — never sent as
"none found".** Rule 1's UNCITED class is a heuristic that gives no clearance,
so a "none found" line would read to the auditor as a clean bill nobody issued.
Feeding Rule 1 into Rule 4 is one-directional by design: disabling Rule 1
degrades Rule 4's targeting to (b)/(c) and breaks nothing, which is why 090 is
`blocked-by` 088 while their toggles stay independent.

**"No tension" names ONE channel, and the log line must say so.** The Step 3
validators' findings merge separately and may be non-empty while codex returns
nothing — a different state from "everything is clean". There is exactly one
format, carrying both counts, used by the trigger, the waiver, and the report
row alike:

```
CROSS-MODEL: no tension — codex clean on N/N conclusive plans, primary validation raised M findings — <running one premise-directed pass | premise pass WAIVED (<reason>)>
```

A "no tension" line with neither a premise-pass result nor a recorded waiver is
**not a legal report state**. Two boundaries hold that line honest: an
`audit-inconclusive` plan is **not** a clean plan (it contributes no findings by
design, so counting it would let a codex timeout manufacture the unanimity the
trigger exists to distrust), and the trigger fires **at most once per doctor
run** over the conclusive-and-clean plans only — a per-plan version would fire
on every clean single-plan run and turn a smell check into a tax.

**The batch trigger stays where batches are.** `mstack-code-review`'s scope is a
single diff with no multi-plan aggregation point, so it gets the row
(`CROSS-MODEL: no tension (external reviewer added nothing)`, or `n/a (single
reviewer)`) and **no extra pass**. Importing plan-doctor's trigger there would
be a category error, and the row states reviewer-vs-reviewer agreement on one
diff, never agreement across plans.

**Honest residual — do not overclaim any part of this.** A brief cannot make a
model independent. It changes what the model is pointed at, which is the
demonstrated differentiator in exactly one case (a third model with an
adversarial mandate found what two models with a confirmatory mandate missed).
It is not a guarantee, and the no-tension trigger is a **smell heuristic, not a
detector**: unanimity has innocent causes (a genuinely small, genuinely clean
batch) and a briefed model can still read confirmingly. What the rule buys is
that unanimity now costs one pass or one recorded waiver instead of being cited
as a second confirmation.

**Rule 4 is PROSE, which is why `brief-content-smoke.sh` exists.** Every other
rule in this family has a script that fails when it breaks. This one's mechanism
is four paragraphs; delete one and the audit still runs, codex still answers,
the report still prints, and the pipeline is silently back to the brief that
cleared two P1s. That is plan 045's fail-safe-default problem in its purest
form — the degraded path is indistinguishable from the working one — so the
directives are asserted by a suite or they are not covered at all. The suite
matches short load-bearing phrases over whitespace-normalized text (honest
rewording survives, deletion does not) and asserts the untouched machinery too:
sandbox flags, `< /dev/null`, `2>"$TMPERR"`, the 300s timeout, the `FINDING:`
schema, the GENUINE/FORWARD-DEPENDENCY classifier. A rewrite that adopts the new
mandate while dropping one of those has broken the audit in a way the mandate
checks alone would pass.

## Nobody Reviews The Reviewer (Rule 2, plan 091)

**The highest-churn text in this pipeline is the text reviews WRITE, and it is
the only text nothing reviews.** One of the two P1s in the cctrl 051-053 batch
was not in the original plan — the eng review *created* it, correctly replacing
a too-loose negative readiness form with an allow-list that turns out to be
unsatisfiable for codex sessions. The fix was right in direction and wrong in
fact, and it shipped with zero scrutiny because an amendment folded in during
review is stamped cleared along with everything else. This is the standard
regression problem — fixes need review too — appearing at the plan layer.

mstack had the same hole in a different shape. Plan-doctor's Step 4b already
re-validates a plan the doctor edited, *structurally*: frontmatter, scoring,
seam diffs, the audit. What it never did was look at the **amendment itself**
with the one question that catches this class: *assume this fix introduced a new
defect; find it.*

The mechanism is `skills/mstack-run/scripts/amendment-repass.sh`, wired into
`mstack-plan-doctor` Step 4b (capture + re-pass), Step 5 (the around-the-review
capture), Step 4 (the `AMEND` report row) and Step 6 (the gate). Four
subcommands:

- `capture <plan> <round> <severity> <trigger>` — persist the pre-edit image of
  the plan file together with the classification of the finding being fixed.
- `diff <plan> <round>` — the unified diff pre-image → current. **The only text
  the re-pass reviewer is given.**
- `record <plan> <round> <severity> <trigger> <by> [defects]` — append the
  re-check record. Refuses a round with no matching capture, so a mis-numbered
  round is a hard error rather than a false clearance.
- `assert-rechecked <plan>` — exit `EXIT_AMENDMENT_UNCHECKED` (39) when any
  captured P2-or-above amendment has no matching re-check.

**The severity signal is produced by this rule, not assumed.** Nothing else in
the pipeline classifies an amendment — Step 4b knows only that a plan's hash
changed, and which finding drove the edit is information the doctor holds at
edit time and immediately discards. So the doctor is the producer and the
capture sites are enumerated, not implied:

| Capture site | Severity | Trigger |
|---|---|---|
| GENUINE adversarial-audit finding auto-fixed (Step 3.5) | `p2` | `audit-genuine` |
| Blocking SEAM fix — MISSING / SHAPE-DIVERGENT (Step 3.6) | `p2` | `seam-blocking` |
| `[critical]` frame-review finding fixed (Step 2c) | `p2` | `frame-critical` |
| A review skill edited the plan (Step 5, around the invocation) | `p2` | `review-edit` |
| Autonomy-readiness auto-fix (Step 2) | `p3` | `autofix-autonomy` |
| Verification / testability auto-fix (Step 2) | `p3` | `autofix-verification` |
| Trap-resistance auto-fix (Step 2) | `p3` | `autofix-trap` |
| Mechanical-error auto-fix (Step 4) | `p3` | `autofix-mechanical` |

A P3 site escalates to `p2` when the finding that triggered it was itself P2 or
above. The review path captures **around the invocation** rather than at a fix
site, because the plan edit comes from the review skill, which mstack does not
own; the `changes-requested` branch is deliberately NOT instrumented, since it
records a verdict and applies no fix.

**Strict 4-arity on `capture`, and the asymmetry is the design.** Fewer than
four arguments is a usage error that exits nonzero and writes nothing — there is
no short form, because a silently defaulted argument is exactly how the
classification signal would rot back to absent while the records still looked
complete. An *unrecognized* severity token is tolerated and stored as `p2`:
unknown means "needs the re-check", never "skip it". The cost asymmetry is the
one the review gate settles the same way — a needless re-pass costs one bounded
call; a skipped re-pass on a fix that introduced a P1 costs what the 051-053
batch cost.

**Scope discipline is what keeps this bounded.** The re-pass reviewer gets the
amendment diff and the plan's acceptance criteria — not the plan, not the repo —
routed through the outside voice with plan 090's premise-attack framing when
codex is available, same-model when it is not. A re-pass that re-reads the whole
plan is just a second full review under a different name, and the price this rule
was adopted at (~15 minutes against three amended sections) holds only while the
input stays the diff.

**The record is local and non-authoritative by construction.**
`.mstack/amendments/plan-<id>.jsonl` plus pre-images at
`.mstack/amendments/plan-<id>-r<N>.pre`; `.mstack/` is gitignored, so this is
per-checkout working state — invisible to review, absent on a fresh clone, gone
when the directory is cleaned. Same class as `health-history.jsonl` and the
`.mstack/reviews/*.json` cache. It is deliberately NOT frontmatter: the
`reviews:` block is the completion gate's single source of truth and its values
may not contain spaces, so **an amendment record is not a review verdict and
must never become one**. Rule 2 touches no part of `review-gate.sh`, the
`reviews:` block, the completion gate, or `mstack-run` Step 7a.

**Honest residual — this is an HONEST-PATH check ONLY, and the claim stops
there.** It fires when plan-doctor calls `capture`. An agent that edits a plan
without capturing leaves no record, and `assert-rechecked` on a plan with no
records exits 0 — that exit is the absence of evidence, not a clearance. There
is **no write-time hook and no retroactive audit** for amendments: unlike plan
038's completion barrier there is nothing in the commit to inspect (the
amendment and the plan land as one file state) and no durable artifact recording
that an amendment happened. Claiming an audit here would repeat precisely the
overclaim plan 039 explicitly refused to make about uncommitted work. What Rule
2 buys is that an amendment the doctor *did* make can no longer reach `ready`
unexamined — and that is the whole claim.

Disable with `config.sh set rules.amendment_repass false`, which skips capture
and the re-pass and stands Step 6's gate down. Rules 1, 3 and 4 are unaffected;
`rule-toggle-smoke.sh` asserts that independence in both directions.

## Plan Citation Convention

No agent-facing output emits a bare plan ID. Every citation of a plan —
in a printed progress line, a status dashboard, a blocked/crash message,
a learnings header, or a table row — renders `NNN: Title` (the plan's
zero-padded id, a colon, its frontmatter title). Use the `plan_label`
helper in `skills/mstack-run/scripts/lib.sh` (or an equivalent
already-known id/title pair) to build the string; never print a plan id
on its own and make the reader open the repo to learn what it is. When a
message lists several dependency ids (e.g. "blocked by 026"), render each
one as `026: Title`.

Machine identifiers are exempt and MUST stay bare — do not "helpfully"
rewrite them: git commit message subjects and bodies, the
`mstack/plan-${PLAN_ID}-done` git tag, machine-readable JSON fields
(e.g. `plan_id` in checkpoint or `.mstack/reviews/plan-*.json`), and
evidence path names (e.g. `.mstack/evidence/plan-032/`). These are parsed
by scripts or `git`, not read as prose; adding a title would break the
parser or the identifier's shape.

## Compatibility Rules

- Treat `AGENTS.md` as the primary project guidance file for Codex.
- Treat `CLAUDE.md` as a compatibility import file for Claude Code.
- When skills need to read project guidance, support both `AGENTS.md` and
  `CLAUDE.md`.
- When skills need to locate installed MStack assets, prefer path resolution
  that works across Skillshare, Codex, and Claude:
  `~/.config/skillshare/skills`, `~/.agents/skills`, `~/.codex/skills`, then
  `~/.claude/skills`.
- Prefer agent-neutral wording in shared MStack instructions. Call out
  Claude-only or Codex-only behavior explicitly when the behavior differs.

## Development Commands

Run focused checks after changing shell helpers:

```bash
bash -n skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
shellcheck skills/mstack-run/scripts/*.sh bin/mstack-update-check setup
```

The smoke suites. Run **all** of them after touching anything under `scripts/`;
each is self-contained, deterministic, and takes seconds:

```bash
bash skills/mstack-run/scripts/script-mode-smoke.sh    # shipped scripts are 100755
bash skills/mstack-run/scripts/review-gate-smoke.sh
bash skills/mstack-run/scripts/verify-lint-smoke.sh    # incl. the injection cases
bash skills/mstack-run/scripts/health-reach-smoke.sh   # gate-covers-declared-tests invariant
bash skills/mstack-run/scripts/health-score-smoke.sh   # every detected category reaches the composite
bash skills/mstack-run/scripts/wrapup-scan-smoke.sh
bash skills/mstack-run/scripts/plan-ref-smoke.sh
bash skills/mstack-run/scripts/hook-chain-smoke.sh
bash skills/mstack-run/scripts/pick-next-smoke.sh     # picker exit-code contract, dep parsing, ordering
bash skills/mstack-run/scripts/premise-lint-smoke.sh  # the four citation classes + the plans-dir exclusion
bash skills/mstack-run/scripts/rule-toggle-smoke.sh   # rules.<key> fails OPEN; only an exact false disables
bash skills/mstack-run/scripts/fixture-lint-smoke.sh  # pane-dependent plans block without a real capture
bash skills/mstack-run/scripts/brief-content-smoke.sh # the shipped briefs still carry Rule 4's directives
bash skills/mstack-run/scripts/amendment-repass-smoke.sh # a P2 amendment cannot reach ready un-re-checked
```

Other useful checks:

```bash
bash skills/mstack-run/scripts/config.sh show
bash skills/mstack-run/scripts/status.sh
bash skills/mstack-run/scripts/pick-next.sh
bin/mstack-codex-smoke
```

`pick-next.sh` exits with code `10` when all plans are done; that is expected
for an empty backlog.

**A new script must be committed executable** (`100755`). An agent's Write tool
does not set the bit, and a helper that lacks it is silently unresolvable to any
consumer that probes with `[ -x ]` — `script-mode-smoke.sh` exists because that
shipped once and went unnoticed. When adding a script:
`chmod +x <path> && git update-index --chmod=+x <path>`.

**The suites also run automatically at commit time in THIS repo.** The
`pre-commit` hook runs all fourteen whenever the staged set touches an executable
surface (`skills/**/*.sh`, `skills/mstack-run/hooks/`, `bin/`, `setup`) and
refuses the commit on failure; a prose/doc/plan-only commit skips them and pays
nothing. This is a **dev guard, not shipped product** — it is gated on the
checkout actually containing `skills/mstack-run/scripts/`, so a consumer repo
that receives the same hook skips it entirely.

Edit the hook at its SHIPPED SOURCE, `skills/mstack-run/hooks/pre-commit`, then
copy it to `.githooks/pre-commit`. The tracked `.githooks/` copy is refreshed
from that source by `mstack-init`/`setup` on every run, so an edit made only in
`.githooks/` is silently clobbered later. Two honest limits: the suites exercise
the working tree rather than the staged content (a partially-staged commit can
pass while the committed subset would not), and `--no-verify` /
`MSTACK_SKIP_SMOKE=1` bypass it. Same deterrent-not-proof posture as the rest of
plan 038.

**Do not run `./setup` merely to sync the hook** (or for any routine purpose).
From a development checkout it now links into the configured Skillshare source,
not `dirname(repo)`, but it also refreshes hooks and may run `skillshare sync`.
Use `cp` for a hook-only refresh.

## MStack Modifying MStack Runs Manually First

This repository is the one place where the tool under change is also the tool
running the change. A plan that edits the picker, the completion sequence, or
the health gate is executed BY the picker, the completion sequence, and the
health gate. A bug introduced mid-plan does not fail the next run — it can
corrupt the run that introduced it, and the corruption is reported by the same
machinery that is broken.

So: **a plan that modifies `pick-next.sh`, the Step 7a completion sequence (or
a future `complete.sh`), `health-check.sh`, `result-gate.sh`, or
`review-gate.sh` is executed in a SCOPED, manual `mstack-run` invocation — one
plan, watched — and its smoke suites are run by hand afterward, before the
autonomous loop is trusted again.** Never let an unattended `/goal` run sweep
through a batch of them.

Two consequences that are easy to get wrong:

- **Characterization tests land BEFORE the change, not after.** A smoke suite
  sequenced after the rewrite it protects pins the new behavior and can no
  longer tell you the rewrite altered something it should not have. If a plan
  rewrites load-bearing internals, the suite covering current behavior is a
  prerequisite, not a follow-up.
- **A green health gate proves less than usual here.** When the plan under
  execution is the one changing the gate, the gate's verdict about its own
  change is not independent evidence. Run the suites in a separate invocation
  after the commit lands.

This is process doctrine, not an enforced mechanism — there is no script that
can detect "you are modifying the thing executing you" and refuse. It is
written down because the failure is silent and the batch is large.

## Editing Expectations

- Keep changes scoped to the relevant skill, script, or reference.
- Do not rewrite archived plans unless the task is explicitly archival cleanup.
- Do not revert unrelated local changes. This repo is often dirty during
  active MStack work.
- Use deterministic shell scripts for behavior that should survive across
  agents; use skill prose for workflow judgment.
