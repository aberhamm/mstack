# Trap Resistance: Categories, Heuristics, and Auto-fix

## Strict boundary vs. other dimensions

Trap resistance is distinct from the other four dimensions. Clarity asks
"can someone understand what to build?" (communication). Testability asks
"can we prove it worked?" (verification). Scope-fit asks "is this the right
size?" (granularity). Autonomy-readiness asks "can the worker implement
without asking?" (completeness). Trap resistance asks "will this approach
actually work under real conditions?" (hidden failure modes in the chosen
approach itself, not its description). A plan can be perfectly clear,
testable, well-scoped, and autonomy-ready while still choosing an approach
that will fail at scale.

## Trap categories (each with detection heuristic)

1. **Premature abstraction:** Plan introduces a generic framework or
   abstraction when a direct implementation would suffice. Detection
   heuristic: plan mentions "reusable", "extensible", "generic" for a
   first implementation.

2. **False economy:** Plan takes a shortcut that creates more work
   downstream. Detection heuristic: plan skips a step "for now" or defers
   a concern that blocked-by plans will need.

3. **Hidden coupling:** Plan's approach creates implicit dependencies not
   captured in blocked-by. Detection heuristic: plan modifies shared state,
   globals, or files also listed in other plans without a dependency edge.

4. **Won't-scale pattern:** Approach works for current data size but has
   O(n^2) or worse characteristics. Detection heuristic: plan uses
   in-memory processing, nested loops, or synchronous calls for data that
   could grow.

5. **Scope creep magnet:** Plan's design is broad enough that the worker
   will be tempted to expand scope. Detection heuristic: "Out of scope"
   section is missing or thin relative to the plan's breadth.

## Scoring rubric

- 10: No traps detected. Approach is direct and proportionate.
- 7-9: Minor trap risk. One advisory-level pattern that probably will not
  bite.
- 4-6: Moderate trap risk. One or more patterns that could cause rework.
- 1-3: High trap risk. Approach is likely to fail or create significant
  downstream cost.

## Trap findings output

For each detected trap, report:
- Trap name (a short descriptive label)
- Trap category (one of the 5 categories above)
- One-line mitigation suggestion

Plans scoring below 6/10 on trap resistance get an explicit warning with
the specific trap identified.

## Auto-fix: trap resistance

After scoring, if any plan scores below 4 on trap resistance (high risk),
**automatically fix it** without asking. Read the codebase to infer a
safer approach, then edit the plan's Design section to mitigate the
identified traps. Follow the same pattern as autonomy-readiness auto-fix:

1. Identify the specific trap(s) causing the low score
2. Read sibling implementations, existing patterns, and project conventions
   to determine a safer alternative
3. Edit the plan's Design section with the mitigation (e.g., replace a
   premature abstraction with a direct implementation, add missing
   dependency edges for hidden coupling, add explicit "Out of scope" items
   for scope creep magnets)
4. Re-score to confirm improvement
5. Log what was fixed:

```
Auto-fixed trap resistance:
  042, "Add user avatars": replaced generic image pipeline with direct sharp resize
    (was 3/10 premature abstraction, now 8/10)
  045, "Redesign settings": added blocked-by edge to plan 043 for shared Settings.tsx
    (was 2/10 hidden coupling, now 7/10)
```

If a trap cannot be resolved by editing the Design section (e.g., the
entire approach is fundamentally flawed and needs rethinking), flag it as
a **user challenge** for the architect with the specific trap category and
a suggested alternative approach.
