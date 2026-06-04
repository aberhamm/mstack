## Step 4: Critic pass

After all branches are complete, switch to evaluation mode. Score every
idea across all branches on three axes.

### Evaluator prompt

```
You are a skeptical evaluator. Score each idea honestly. Flag ideas that
look good on paper but will not survive contact with reality. Do not
generate new ideas. Do not soften scores to be nice. A score of 3 is
not an insult; it is useful information.
```

### Scoring axes

| Axis | Scale | Measures |
|---|---|---|
| Novelty | 0-10 | How different from the obvious/default approach. 0 = everyone's first idea. 10 = genuinely surprising. |
| Viability | 0-10 | Can this actually be built and maintained. 0 = fantasy. 10 = straightforward to ship. |
| Fit | 0-10 | How well it solves the stated problem. 0 = tangential. 10 = direct, complete solution. |

### Weighted score

Compute a weighted total for each idea:

```
score = (viability * 0.4) + (novelty * 0.35) + (fit * 0.25)
```

Weights rationale: viability is heaviest because ideas that cannot ship
are worthless. Novelty is next because the whole point of ideation is
to surface non-obvious approaches. Fit is lightest because a great idea
that partially solves the problem is more valuable than a mediocre idea
that fully solves it (scope can be adjusted later).

### Trap detection

After scoring novelty/viability/fit, evaluate each idea for the five
trap categories. Trap-flagged ideas keep their score but get a visible
warning. The user decides whether the trap is acceptable or disqualifying.

**Trap categories:**

| Trap | Definition |
|---|---|
| Premature Abstraction | Introducing generality, indirection, or framework-level structure before the concrete use cases are known. Adds complexity now for flexibility that may never be needed. |
| False Economy | Choosing something that looks simpler or cheaper up front but hides costs that surface later: migration effort, operational burden, performance walls, missing capabilities that force workarounds. |
| Hidden Coupling | Creating a dependency between components that is not visible in the interface: shared mutable state, implicit ordering, ambient configuration, or runtime assumptions that break when either side changes independently. |
| Won't-Scale Pattern | An approach that works at current load/size but has a structural ceiling: O(n^2) loops, single-writer bottlenecks, in-memory stores that outgrow one machine, polling intervals that multiply with users. |
| Scope Creep Magnet | A design surface that invites unbounded follow-on work: plugin systems, configuration DSLs, "make it customizable" layers, or open-ended extension points that each generate their own backlog. |

**Trap evaluation prompt:**

```
For each idea, check: does this approach contain a trap?

If a trap is detected, flag it with the category and a one-line explanation
of the specific cost the trap creates in this context.
```

If no trap is detected for an idea, do not force one. Only flag genuine risks.

### Critic output format

For each idea, record:

```
IDEA: <title> (from <frame name>)
  Novelty:   <score>/10 - <one-line justification>
  Viability: <score>/10 - <one-line justification>
  Fit:       <score>/10 - <one-line justification>
  Weighted:  <computed score>
  Trap:      none | TRAP [<category>]: "<one-line explanation>"
```

Example trap flag:

```
  Trap:      TRAP [false economy]: "SQLite avoids setup cost but requires
             a Postgres migration within 3 months at projected load."
```
