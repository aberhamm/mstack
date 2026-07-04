---
id: 039
title: Completion requires the work product committed — no dirty terminal state
status: pending
blocked-by: [034, 036, 038]
priority:
goal: plan-ref-and-review-gates
allows-migrations: false
needs-review: none
created: 2026-07-04
---

## Requirements

Plan 036 makes completion fail closed on an open *review* gate; plan 037 commits
the approved *plan file* at approval time. Neither guarantees the agent's actual
*work product* — the code and changes it wrote executing the plan — is committed
when the plan is marked done. "Done with a dirty/uncommitted working tree" must
not be a valid terminal state.

Today `mstack-run` Step 7a commits by an **explicit** `MODIFIED + CREATED` file
list taken from the subagent's `---MSTACK-RESULT---` block (`SKILL.md:619-655`).
That is trust-the-list, not verify-the-tree: if the result block's file list is
incomplete, if the agent left stray edits or new untracked files, or if a plan
is completed "outside the picker", the plan can be tagged `mstack/plan-NNN-done`
while implementation changes sit uncommitted. The commit + tag then don't
actually contain the work — the paper trail has a hole exactly where the code
should be. And relying on "the agent should commit" as convention is the very
anti-pattern this enforcement family exists to remove.

**Acceptance criteria:**

- [ ] The `PRE_DIRTY` baseline is **persisted to disk**, not left as an ephemeral
      shell variable. Shell state does not survive between the capture point
      (`SKILL.md:413`) and Step 7a, and `assert-work-committed` runs in a separate
      process — so the baseline must be written to a gitignored file
      (`.mstack/pre-dirty-<PLAN_ID>.txt`) at capture time. `assert-work-committed`
      reads it; a **missing baseline file fails closed** (cannot verify → not
      completable). Adding this Step-3 write is part of this plan's file changes.
- [ ] The porcelain parse is **rename/delete/quote/untracked-safe** on BOTH the
      capture side and the check side: use `git status --porcelain -uall -z`
      (NUL-delimited, `-uall` to list files inside new dirs individually,
      rename-aware) via a shared `lib.sh` helper. The current
      `awk '{print $2}'` capture (`SKILL.md:413`) is replaced — it drops rename
      targets, mangles spaced/quoted paths, and collapses untracked directories
      (a false negative: new work inside a pre-existing untracked dir would be
      invisible to the check). Fixing this parser is the crux of correctness.
- [ ] `review-gate.sh assert-work-committed <plan>` exits nonzero if, at
      completion time, any tracked-dirty or untracked path — normalized via the
      helper — is **not** in the persisted baseline. Fail closed. Pre-existing
      dirt in the baseline for **files the plan did not touch** is allowed and
      never force-committed.
- [ ] Deletions and renames are actually committable: the `---MSTACK-RESULT---`
      block gains a `DELETED` list (worker declares removed paths — add it in
      BOTH the hard-rules two-list declaration at `subagent-prompt.md:23` AND the
      result-block format at `subagent-prompt.md:122-133`, next to MODIFIED
      `:125` / CREATED `:126`), and Step 7a stages them (`git rm` / `git add -A`
      on the explicit list). Without this, a plan that deletes or renames a file
      leaves a `D`/`R` entry the file-list commit never stages, so
      `assert-work-committed` would block every deletion-bearing plan forever.
- [ ] `mstack-run` Step 7a runs `assert-work-committed` at the correct point in
      the completion sequence (see Design for the full order incl. the amend and
      archive `git mv`). On failure it **halts and reports the stray paths** — it
      does NOT auto-`git add` them (that would be the forbidden `git add .` sweep,
      committing undeclared build junk). No `mstack/plan-*-done` tag is created
      while the tree has plan-attributable dirt.
- [ ] The instruction is explicit in the **orchestrator/completion-facing** prose
      (`mstack-run` Step 7a, `references/implement-spec.md`,
      `references/review-spec.md`): the completing orchestrator MUST commit all
      declared work product on completion, and a dirty plan-attributable tree
      fails the plan. Not convention — a stated rule plus the enforcement above.
- [ ] The **worker subagent** prompt is NOT changed to commit — it keeps its
      "never commit, leave all changes uncommitted" contract
      (`subagent-prompt.md:20`) so the health gate can still roll back on failure.
      The commit + clean-tree enforcement lives with the orchestrator, after the
      gate passes. (Required design point, not an oversight.)
- [ ] **Honest enforcement scope (no overclaim).** The Step 7a honest-path check
      is the real enforcement. A `pre-commit` hook *cannot* detect uncommitted
      work (by definition it's not in the commit), and no durable artifact records
      "the tree was dirty at completion", so 038's **retroactive audit cannot
      enforce this rule** — do not claim it does. The only non-optional touch is
      an optional, clearly-caveated `pre-push` guard in 038 that rejects pushing a
      `mstack/plan-*-done` tag while `git status` is dirty — best-effort, TOCTOU,
      and `--no-verify`-able. State this residual plainly.

## Design

**Baseline is `PRE_DIRTY`, persisted at plan start.** The rule is
`(current porcelain set) minus baseline == empty` at completion. The baseline is
written to `.mstack/pre-dirty-<PLAN_ID>.txt` (gitignored, so it never itself
shows in porcelain) at the capture point, because the ephemeral shell variable at
`SKILL.md:413` does not survive to Step 7a or into a separate script process. The
subtraction distinguishes "the plan left work uncommitted" (block) from "the user
had unrelated edits open before the run" (allow). Both sides must be produced by
the SAME normalizer (the `-uall -z` helper), or the subtraction compares
differently-shaped sets and silently mis-classifies.

**Conflict files are the honest exception (was overstated).** The existing Step 7a
commit stages all of `MODIFIED`, which includes a file that is both plan-touched
and pre-dirty (`MODIFIED ∩ PRE_DIRTY`); `implement-spec.md:26-29` already admits
"the commit will include both." So such a file **is** committed with the user's
pre-existing changes baked in, and `assert-work-committed` (which excludes
baseline paths) passes. The "never force-committed" guarantee therefore holds
only for files the plan did **not** touch; conflict files remain
committed-together per today's behavior. Say this explicitly rather than implying
pre-existing work is always safe.

**Interaction with existing PRE_DIRTY handling.** Step 7b reverts non-baseline
changes on failure and leaves conflict files alone (`SKILL.md:710-714`). The
success path (this plan) is the mirror: on success, non-baseline changes must be
*committed* (via the declared list), not reverted. Same baseline, so success and
failure agree on "attributable".

**Full Step 7a linear order (spell it out; 036 inserts at the top, 039 near the
end, and there are commits in between).** review-gate assert-completable (036) →
stage declared `MODIFIED + CREATED + DELETED` and commit (`SKILL.md:651`) →
backfill-hash `git commit --amend` (`:668-672`, this re-touches `$NEXT`) →
**assert-work-committed (039)** → archive `git mv "$NEXT" archive/` + its commit
(`:676-678`, transiently dirties then re-cleans the tree) → tag (`:681`). Placing
039's check after the amend and before the archive means the tree it inspects is
exactly the post-work state; the archive commit re-cleans before the tag, so an
optional pre-push tag guard still sees a clean tree. State this so an executor
does not interleave 036 and 039 incorrectly.

**Files expected to change:**

- `skills/mstack-run/scripts/lib.sh`: a shared `porcelain_paths` helper
  (`git status --porcelain -uall -z`, rename/quote/untracked-safe) used by BOTH
  the baseline capture and `assert-work-committed`; any exit-code constant.
- `skills/mstack-run/scripts/review-gate.sh`: add `assert-work-committed` (reads
  the persisted baseline; fail-closed if absent).
- `skills/mstack-run/SKILL.md`: replace the `awk '{print $2}'` capture at ~413
  with the helper + persist to `.mstack/pre-dirty-<PLAN_ID>.txt`; Step 7a — stage
  `DELETED` too, wire `assert-work-committed` at the defined point, add the
  explicit commit-your-work instruction and halt-and-report-on-dirty behavior.
- `skills/mstack-run/references/subagent-prompt.md`: add the `DELETED` list to the
  `---MSTACK-RESULT---` contract (keep the never-commit line).
- `skills/mstack-run/references/implement-spec.md`,
  `skills/mstack-run/references/review-spec.md`: completion-facing commit rule.
- Plan 038's `pre-push` tag guard only (optional, caveated): reject pushing a
  `-done` tag while `git status` is dirty. **No** `pre-commit` clean-tree rule and
  **no** retroactive audit claim (neither can detect uncommitted work).
- `AGENTS.md`: "done ⇒ declared work committed; dirty terminal state is invalid",
  with the honest residual.

**Out of scope:** changing the worker's never-commit contract; committing or
reverting baseline (pre-existing) changes for files the plan didn't touch;
gitignored/generated files (not in porcelain, not plan-attributable);
auto-`git add` of undeclared paths (forbidden — halt and report instead);
handling `MODIFIED ∩ PRE_DIRTY` conflict files differently than today (they stay
committed-together per existing behavior). The failure path (7b) is unchanged.

## Tasks

1. Add the `porcelain_paths` normalizer helper to `lib.sh`; replace the
   `awk '{print $2}'` capture at `SKILL.md:413` with it and persist the baseline
   to `.mstack/pre-dirty-<PLAN_ID>.txt`.
2. Add a `DELETED` list to the `---MSTACK-RESULT---` contract
   (`subagent-prompt.md`) and stage it in Step 7a's commit.
3. Add `assert-work-committed <plan>` to `review-gate.sh` (reads the persisted
   baseline via the helper; fail-closed if the baseline file is absent).
4. Wire it into Step 7a at the defined point (after the amend, before archive);
   on failure, halt + report the stray paths (never auto-`git add`).
5. Add the explicit commit-on-completion instruction to the orchestrator/
   completion prose (NOT the worker prompt; keep its never-commit line).
6. Add the optional, caveated `pre-push` tag guard to 038's hook (dirty tree →
   reject `-done` tag push). Do not add a pre-commit rule or audit claim.
7. Document the invariant + honest residual in `AGENTS.md`.
8. Re-read `review-gate.sh`, Step 7a prose, `review-spec.md`, and `AGENTS.md`
   after 036/038 land (all shared with those plans) before editing, so the
   inserts land in the post-036/038 text.

## Verification

- `[cmd]` `bash -n skills/mstack-run/scripts/review-gate.sh skills/mstack-run/scripts/lib.sh`; `shellcheck` clean.
- `[cmd]` **integration (the load-bearing check):** a Step-7a completion-simulation
  harness on a fixture with a plan-attributable uncommitted change creates **no**
  `mstack/plan-*-done` tag and halts; the mirror fixture (all work committed)
  completes and tags. Proves the wiring, not just the function in isolation.
- `[cmd]` a plan-attributable file left uncommitted (not in baseline) makes
  `assert-work-committed` exit nonzero; after committing, exits 0.
- `[cmd]` a pre-existing dirty file recorded in the baseline, for a file the plan
  did not touch, makes `assert-work-committed` exit 0 (not blocked/force-committed).
- `[cmd]` an **untracked** file created during execution and left unadded trips
  the check; and an untracked file created **inside a pre-existing untracked
  directory** also trips it (proves `-uall`, guarding the B4 false-negative).
- `[cmd]` a fixture that **deletes** a tracked file and a fixture that **renames**
  one both complete cleanly once declared in `DELETED`/`MODIFIED` (proves
  deletions/renames are committable, not permanently blocked).
- `[cmd]` a **missing baseline file** makes `assert-work-committed` fail closed
  (nonzero), not pass.
- `[cmd]` a path with a **space** in it is classified correctly by the normalizer
  (regression against the old `awk '{print $2}'` corruption).
- `[assert]` the worker subagent prompt still contains its "never commit" line
  (regression guard: this plan must not have flipped the worker to commit).
