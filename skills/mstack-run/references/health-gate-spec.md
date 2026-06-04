# Step 5: Verification gate (mstack-code-health)

Run the health check script. It discovers tools, runs them, scores each
category 0-10, computes a weighted composite, persists to history, and
returns a structured verdict:

```bash
PLAN_ID="$PLAN_ID" bash "$SKILL_DIR/scripts/health-check.sh" run
```

Parse the output; each line is `KEY:VALUE`:

```
VERDICT:PASS
COMPOSITE:9.1
TYPECHECK:10
LINT:8
TEST:10
DEADCODE:7
SHELL:10
DURATION:23
FAILURES:none
```

**Progress:** After parsing the health output, print:
```
[mstack] ├─ Health gate: <COMPOSITE>/10 (<VERDICT>)
```

Act on the VERDICT line:
- **PASS** (composite >= 7.0, no category at 0) → proceed to Step 5b
- **FAIL** (composite < 7.0, or any category at 0) → enter investigation
- **REGRESSED** (composite dropped >= 1.0 from previous) → enter investigation

## On FAIL or REGRESSED: mstack-investigate

Instead of retrying blindly, run structured debugging using
mstack-investigate logic:

1. Read the plan file for context (acceptance criteria, expected files)
2. Collect symptoms from health output (which tools failed, exact errors)
3. **Phase 1**: Root cause investigation: trace code, check changes, search learnings
4. **Phase 2**: Pattern analysis: match against known failure patterns
5. **Phase 3**: Hypothesis testing with mandatory reflection before each attempt:
   ```
   ATTEMPT N/3
   Previous: <what was tried>
   Hypothesis: <specific, testable claim>
   Am I repeating myself: <yes/no>
   ```
6. **Phase 4**: Minimal fix + regression test

**Category-aware strike rule:** 3 strikes per root cause category, max 3
categories (9 total attempts). After all categories exhausted, mark the
plan failed with detailed diagnosis. Do not enter a retry loop.

If investigation succeeds (FIXED): re-run the health check to confirm,
then proceed to Step 5b.

If investigation fails (3 strikes exhausted): Step 7 failure path.
