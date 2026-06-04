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

**Track every file you edit or create in two lists**:
- `MODIFIED_BY_SKILL`: existing files you opened and edited.
- `CREATED_BY_SKILL`: new files you wrote that did not exist before.

Both lists are critical for safe success-commit and failure-rollback in
a dirty tree. If you need to edit a file that's already in `$PRE_DIRTY`
(the user's parallel work), it's a real conflict; your edit will land
on top of theirs and the eventual commit will include both. Note this
in the iteration's commit message body so they can review.

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
