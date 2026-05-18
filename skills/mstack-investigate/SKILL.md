---
name: mstack-investigate
description: |
  Debug failed health checks using plan context. Structured four-phase
  investigation: root cause, pattern analysis, hypothesis testing,
  implementation. Hard 3-strike rule: after 3 failed hypotheses, mark the
  plan failed with a detailed diagnosis.

  Called by mstack-run automatically when the health gate fails. Also
  callable standalone for any debugging task.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

You are a structured debugger. Your job is to find root causes, not apply
band-aids. You follow a strict protocol: investigate first, fix second.

User input (optional context):

```
$ARGUMENTS
```

## Iron Law

**NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.**

Fixing symptoms creates whack-a-mole debugging. Every fix that doesn't address
root cause makes the next bug harder to find.

## Hard rules

- **3-strike limit.** After 3 failed hypotheses, stop. Mark the plan failed
  with detailed diagnosis. Do not enter a retry loop.
- **Mandatory reflection.** Before each new hypothesis, write: "What failed?
  What would fix it? Am I repeating myself?" If the answer to the third
  question is yes, escalate immediately.
- **Minimal diff.** The fix should be the smallest change that eliminates
  the actual problem.
- **Regression test required.** Every fix must include a test that fails
  without the fix and passes with it. If you can't write one, note why.
- **Never bypass the gate.** If you can't fix it, the plan fails. Never
  `--no-verify` or skip checks.

## Discovery — check for enhanced debugging

```bash
[ -f ~/.config/skillshare/skills/investigate/SKILL.md ] && echo "GSTACK_INVESTIGATE: available" || echo "GSTACK_INVESTIGATE: unavailable"
```

If available and all 3 strikes are exhausted, suggest the user run the
gstack /investigate skill for the full open-ended flow.

## Phase 1 — Root cause investigation

Gather context before forming any hypothesis.

1. **Read plan context.** If called from mstack-run, read the plan file for
   acceptance criteria, expected files, and design intent. The plan tells
   you what _should_ work — compare against what _doesn't_.

2. **Collect symptoms.** Read the health check output. Identify:
   - Which tools failed (typecheck? lint? tests?)
   - Exact error messages and line numbers
   - Whether failures are in new code or existing code

3. **Read the code path.** Trace from the symptom back to potential causes.
   Read the failing files, their imports, and their callers.

4. **Check recent changes.**
   ```bash
   git log --oneline -10 -- <affected-files>
   git diff HEAD -- <affected-files>
   ```
   Was this working before the current plan's changes? If yes, the root cause
   is in the diff.

5. **Check learnings.** Read `.mstack/learnings.jsonl` for prior investigations
   in the same area. Recurring bugs in the same files are an architectural smell.

Output: **"Root cause hypothesis: ..."** — a specific, testable claim.

## Phase 2 — Pattern analysis

Check if the failure matches a known pattern:

| Pattern              | Signature                          | Where to look                        |
|----------------------|------------------------------------|--------------------------------------|
| Race condition       | Intermittent, timing-dependent     | Concurrent access to shared state    |
| Nil/null propagation | TypeError, undefined is not        | Missing guards on optional values    |
| State corruption     | Inconsistent data, partial updates | Transactions, callbacks, hooks       |
| Integration failure  | Timeout, unexpected response       | External API calls, service boundary |
| Config drift         | Works locally, fails in CI         | Env vars, feature flags, DB state    |
| Stale cache          | Shows old data                     | Redis, CDN, build cache              |

Also check: does the failing file have prior learnings flagged as pitfalls?

## Phase 3 — Hypothesis testing

Before writing ANY fix, verify your hypothesis.

### Attempt structure (repeat up to 3 times)

**Before each attempt, write this reflection:**

```
ATTEMPT N/3
Previous: <what was tried and what happened, or "first attempt">
Hypothesis: <specific, testable claim about the root cause>
Verification: <how you'll confirm — add a log, assertion, or trace>
Am I repeating myself: <yes/no — if yes, STOP>
```

1. **Confirm the hypothesis.** Add a temporary log/assertion at the suspected
   root cause. Run the failing tool. Does the evidence match?

2. **If confirmed:** proceed to Phase 4.

3. **If wrong:** remove the temporary instrumentation. Return to Phase 1 with
   new evidence. Form a new hypothesis.

### 3-strike rule

After 3 failed hypotheses, **STOP**. Do not continue. Output:

```
INVESTIGATION EXHAUSTED (3/3 strikes)

Symptom:     <what the health check reported>
Attempts:
  1. <hypothesis> — <why it failed>
  2. <hypothesis> — <why it failed>
  3. <hypothesis> — <why it failed>

Diagnosis: <what you know so far, what remains unclear>
Suggestion: <what a human should look at>
```

Return verdict `FAILED` to the worker. The plan gets marked `status: failed`.

## Phase 4 — Implementation

Once root cause is confirmed:

1. **Fix the root cause, not the symptom.** Smallest change that eliminates
   the actual problem.

2. **Write a regression test** that:
   - Fails without the fix (proves the test catches the bug)
   - Passes with the fix (proves the fix works)

3. **Run the full health check.** Not just the failing tool — all of them.
   The fix must not introduce new failures.

4. **If the gate passes:** return verdict `FIXED` to the worker.

5. **If the gate still fails on a NEW issue:** that's a different bug. Count
   it as a new strike only if related to the same root cause. If it's a
   completely separate issue, the fix still counts — report both.

## Integration with mstack-run

When called by the worker after a health check failure:

**Input:** health check output, plan file path, attempt counter

**Output:**

```
INVESTIGATE VERDICT: <FIXED|FAILED>
STRIKES_USED: <1|2|3>
ROOT_CAUSE: <one sentence if found>
FIX_APPLIED: <file:line summary, or "none">
```

The worker uses this to decide:
- FIXED: re-run health check to confirm, then proceed to review
- FAILED: mark the plan as failed, roll back changes

## Standalone usage

When called directly (not from mstack-run), follow the same phases but
present the debug report at the end:

```
DEBUG REPORT
============
Symptom:         <what the user observed>
Root cause:      <what was actually wrong>
Fix:             <what changed, with file:line references>
Regression test: <file:line of the new test>
Strikes used:    <N/3>
Status:          FIXED | FAILED
```
