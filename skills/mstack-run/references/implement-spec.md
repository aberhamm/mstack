# Step 4: Implement (no commits yet)

**Progress:** Before starting implementation, print:
```
[mstack] ├─ Implementing...
```

Make the changes required by the plan. **Do not commit during
implementation**; uncommitted edits let us cleanly rollback if the gate
fails.

A plan in the queue is a contract: the human already decided it is
ready to ship. **Implement it fully.** Do not abandon on size judgment,
do not split it mid-iteration, do not stop because "this looks like a
lot," even if it spans hundreds of lines across many files. There is
no wall-clock budget. An LLM iteration is bounded by context window
and output tokens, **not minutes**, and modern models have ample room
for plans an order of magnitude larger than what would fit in a
human-sized "30 minutes."

**Track every file you edit, create, or remove in three lists**:
- `MODIFIED_BY_SKILL`: existing files you opened and edited.
- `CREATED_BY_SKILL`: new files you wrote that did not exist before.
- `DELETED_BY_SKILL`: files you removed (or the source path of a rename —
  destination goes in CREATED/MODIFIED). The orchestrator stages these as
  removals on completion; a deletion/rename left off this list would sit
  uncommitted and fail the completion check.

All three lists are critical for safe success-commit and failure-rollback in
a dirty tree. If you need to edit a file that's already in `$PRE_DIRTY`
(the user's parallel work), it's a real conflict; your edit will land
on top of theirs and the eventual commit will include both. Note this
in the iteration's commit message body so they can review.

**You still never commit** (see the hard rule above): you leave all changes
uncommitted so the health gate can roll back on failure. The commit itself
happens later, in the orchestrator's Step 7a, after the gate passes.

## Completion requires the work committed (orchestrator, not the worker)

This rule binds the **completing orchestrator** (`mstack-run` Step 7a), not
you the worker — you keep your never-commit contract. Stated here so the
completion contract is documented end to end: on completion the orchestrator
MUST commit all declared work product (`MODIFIED + CREATED + DELETED`), and a
working tree carrying plan-attributable dirt at completion is an **invalid
terminal state that fails the plan** — "done with a dirty tree" is not a valid
outcome. Step 7a's `review-gate.sh assert-work-committed` enforces this on the
honest path (it subtracts the persisted plan-start baseline, so the user's
unrelated pre-existing edits are never blocked or force-committed); on failure
it halts and reports the stray paths rather than sweeping them in with
`git add .`. Your job is therefore to declare every touched path accurately in
the three lists so the orchestrator can stage exactly them.

## Sizing: warn, never stop

If, after reading the plan and the surrounding code, you judge the
scope to be unusually large (rough heuristics: >500 lines moved, >10
new files, deep cross-package refactor, or both extensive new code AND
extensive new tests with mocks), state that in one sentence before you
start implementing, then keep going. The warning lets the human see
your read of scope in the log; it does **not** authorize you to stop.

"Feels like a lot," "would take many tool calls," "spans multiple
files," and "the plan bundles three things" are **not** reasons to
abandon. Plans get authored at the size they need to be. If a plan is
genuinely the wrong size, the human will revise it after seeing the
result, not before you've tried.

## Never clear or weaken a review gate

Adding a `needs-review` tag (e.g. `needs-review: eng` on an incomplete spec
or a stale seam) stays allowed and is unaffected by this rule — that add-a-
gate path is exactly what lets a plan escalate to review.

What is forbidden, always: removing/clearing a `needs-review` tag, editing
`review-required` or `reviews` to clear or weaken them, marking a
needs-review plan `done`, or running a needs-review plan "outside the picker".
Only the named review skill clears a gate, and only by actually running and
recording a passing verdict: `plan-eng-review` / `plan-design-review` /
`plan-ceo-review` (orchestrated by `mstack-plan-doctor`) for eng/design/ceo,
and `mstack-code-review` for `code`. If a plan needs review, run that skill —
do not offer to self-clear `needs-review: eng`, and do not offer to "say go
and I'll proceed outside the picker". Both are the specific anti-pattern this
rule forbids.

## The only legitimate failure modes

- **Gate stays red after investigation** (Step 5, 3-strike rule exhausted).
- **Architectural blocker**: implementing the plan as written would
  require a design decision the plan didn't account for. Record the
  specific blocker in the failure commit so the human can revise.
- **Context exhaustion**: the conversation is genuinely approaching
  the context limit and cannot finish safely. Rare; flag explicitly
  as `failed-reason: context-exhausted`.

Hard cap on investigation: **3 strikes per root cause category, max 3
categories** (see mstack-investigate). This gives up to 9 total attempts
for genuinely complex bugs while still preventing infinite loops.
