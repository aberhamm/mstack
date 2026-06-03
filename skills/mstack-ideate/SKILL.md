---
name: mstack-ideate
description: |
  Divergent idea exploration before committing to plans. Multiple isolated
  reasoning branches under different cognitive frames, scored, trap-checked,
  clustered, and ranked. Output includes a structured handoff for
  /mstack-plan-multi so chosen ideas become plans in one step.
argument-hint: "<problem statement or feature idea>"
triggers:
  - brainstorm
  - explore ideas
  - what could we build
  - ideate
  - think through
  - idea generation
  - generate ideas
  - what are our options
  - diverge on
  - creative solutions
  - explore approaches
  - come up with ideas
  - what if we
  - ideas for
  - how might we
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

You are running `/mstack-ideate`. Take a problem statement, run isolated
reasoning branches under different cognitive frames, and produce ranked
ideas with implementation sketches. Do not generate plans or write code;
produce ideas that feed into `/mstack-plan-multi`.

User input (the problem):

```
$ARGUMENTS
```

## Auto-init

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
bash "$MSTACK_ROOT/bin/mstack-update-check" 2>/dev/null || true
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Step 1: Input parsing

Extract the problem statement from the user's input.

- If `$ARGUMENTS` is non-empty, use it directly as the problem statement.
- If empty, ask the user via AskUserQuestion:
  "What problem or feature idea do you want to explore?"
- Normalize the statement into a single sentence or short paragraph.
  Strip filler ("I was thinking maybe...", "what if we...") down to the
  core problem. Keep domain-specific terms intact; they drive frame selection.

Store the cleaned problem statement for use in subsequent steps.

## Step 2: Frame reading and selection

Load the cognitive frames library and select 3-5 frames based on
the problem's domain.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
[ -d "$SKILL_DIR" ] || SKILL_DIR="${HOME}/.claude/skills/mstack-run"
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
FRAMES_FILE="$MSTACK_ROOT/skills/mstack-shared/cognitive-frames.md"
cat "$FRAMES_FILE"
```

Read `cognitive-frames.md` from the shared library. Use the **Review Frames**
section (not Decomposition Frames; those are for plan-multi).

### Deterministic frame selection

Apply the Selection Rules from cognitive-frames.md, adapted for ideation:

**Step 2a: Mandatory frame.**
Always include **Simplicity Advocate Review** as one generation lens.
This ensures at least one branch pushes toward minimal, pragmatic solutions.

**Step 2b: Domain match.**
Scan the problem statement for domain-specific signals. Apply the first
matching rule from the ordered list in cognitive-frames.md (at most one
domain match). Use the Keywords field from each frame for matching.

| Signal keywords | Frame |
|---|---|
| auth, security, tokens, passwords, credentials, encryption, CORS | Security Review |
| database, query, index, cache, latency, scaling, performance | Performance and Scaling Review |
| UI, UX, form, button, modal, accessibility, frontend, component | End User and Product Review |
| deploy, infra, monitoring, alerting, health check, rollback | On-Call and Operability Review |
| cost, budget, billing, API calls, tokens, usage, LLM, pricing | Cost and Budget Review |

**Step 2c: Fill remaining slots.**
From all review frames not yet selected, count keyword matches against
the problem statement (case-insensitive, partial word matches allowed).
Rank by match count descending, break ties by frame index order from
cognitive-frames.md. Select enough to reach the target count:

- Focused problems (single domain, clear scope): select 3 frames total
- Broad problems (cross-cutting, architectural, multi-domain): select 5 frames total
- Default to 4 when uncertain

Each selected frame becomes one generation branch in Step 3.

## Step 3: Isolated branch generation

For each selected frame, generate ideas through that frame's lens.
Branches must be isolated with no cross-contamination between reasoning paths.

### Generation rules

- Process each frame independently. Do not reference ideas from other branches.
- Each branch produces 2-4 concrete ideas.
- Use the frame's behavioral bias and checklist to shape the ideation angle,
  but invert its purpose: instead of reviewing for problems, use the frame's
  perspective to generate solutions that address its concerns.

### Generator prompt (applied per branch)

For each frame, reason as follows:

```
Frame: <frame name>
Perspective: <frame's behavioral bias, rephrased as a generative lens>

Problem: <the cleaned problem statement from Step 1>

You are a generator, not a critic. Do not evaluate, hedge, or rank.
Produce concrete ideas. Each idea must be something that could be built,
not a principle or aspiration.
```

### Per-idea output format

For each idea within a branch, produce:

```
IDEA: <title>
  Description: <one paragraph, concrete and specific>
  Tradeoff: <the key tension this approach creates>
  Sketch: <3-5 sentences describing the implementation approach,
           specific enough to estimate scope but not a full design>
```

### Isolation enforcement

Generate all branches before proceeding to Step 4. Do not go back and
revise earlier branches based on later ones. The value of this step is
divergence; premature convergence is the failure mode.

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

## Step 5: Cluster by approach

After scoring and trap detection, group ideas by their underlying approach
angle. Two ideas from different frames that both propose the same
architectural bet belong in the same cluster, even if their surface
features differ.

### Clustering prompt

```
Group these scored ideas by their underlying approach, not by surface-level
features or the frame that generated them, but by the fundamental
architectural bet they are making. Name each cluster with a 3-5 word label.
```

### Cluster output format

```
Clusters:
  "<3-5 word label>": ideas #<N>, #<N> (from <frame>, <frame>)
  "<3-5 word label>": ideas #<N>, #<N> (from <frame>, <frame>)
  "<3-5 word label>": idea #<N> (from <frame>)

Convergence signal: <N> frames independently proposed <cluster label> approaches
  -> higher confidence in this direction
```

**Convergence signals:** When two or more frames independently produce ideas
that land in the same cluster, that is a convergence signal. It means the
approach is robust across different evaluation perspectives and deserves
higher confidence. Call this out explicitly for every cluster with 2+ source
frames.

Singleton clusters (one idea, one frame) are fine. They represent unique
angles that only one perspective surfaced.

## Step 6: Rank and present

Sort all scored ideas by weighted score (descending). Present the results
to the user in the following format:

```
IDEATION RESULTS: "<problem statement>"
=====================================================================

Clusters:
  "<cluster label>": ideas #<N>, #<N>
    Convergence: <yes/no> (<N> frames)
  ...

Ranked ideas:
  1. [<score>] <title> (via <frame name>) [cluster: <label>]
     <description>
     Tradeoff: <tradeoff>
     Sketch: <implementation sketch>
     Trap: <none or trap flag>

  2. [<score>] <title> (via <frame name>) [cluster: <label>]
     ...

  3. [<score>] <title> (via <frame name>) [cluster: <label>]
     ...

  (continue for all ideas)

Non-obvious pick: #<N>, <title>
  Highest novelty score among ideas with viability >= 6.
  <1-2 sentences on why this deserves a closer look despite not ranking #1>

Provocation: "What if we took <non-obvious pick or wildest idea> seriously?"
  <2-3 sentences reframing the wildest viable idea as a legitimate strategy.
   Strip the hedging. Describe what the world looks like if this is the
   actual solution, not a thought experiment.>
```

### Non-obvious pick selection

From all ideas with viability >= 6 (the "viable" threshold), select
the one with the highest novelty score. If tied, prefer the one with the
higher fit score. This is the idea most likely to be overlooked in a
conventional planning session.

If no idea has viability >= 6, skip the non-obvious pick section and
note: "No ideas crossed the viability threshold for non-obvious pick."

### Provocation

Take the wildest idea among those with viability >= 4 (a lower bar
than the non-obvious pick). Reframe it as: "What if we took this seriously?"

The provocation is not a recommendation. It is a forcing function to
prevent premature dismissal of unconventional approaches. Write it
without hedging, qualifications, or "of course this probably won't work."

## Step 7: Handoff to plan-multi

After presenting the ranked results, offer the user a structured handoff
to `/mstack-plan-multi`.

### Idea selection

Use AskUserQuestion to let the user choose which idea(s) to develop into plans:

```
Ready to plan? Select idea(s) to hand off to /mstack-plan-multi:

A) #1: <top idea title>
B) #2: <second idea title>
C) #3: <third idea title>
D) Custom: combine elements from multiple ideas
E) None: save results for later with /mstack-stash
```

If the user selects "E" or declines, suggest `/mstack-stash` and stop.
If the user selects "D", ask a follow-up AskUserQuestion for which elements
to combine, then synthesize a combined goal statement.

### Handoff output format

For the selected idea(s), generate a structured handoff block. This is
a ready-to-paste argument for `/mstack-plan-multi`. Do NOT invoke
`/mstack-plan-multi` directly; print the handoff for the user to run.

```
HANDOFF -> /mstack-plan-multi
-------------------------------------------------------------

Goal: <one-sentence goal derived from the selected idea's title>

<one paragraph expanding the goal with specifics from the idea's
description and implementation sketch. Concrete enough for plan-multi
to decompose without asking clarifying questions.>

Constraints from ideation:
- <constraint derived from the idea's tradeoff or frame perspective>
- <constraint derived from another frame's perspective, if relevant>
- <any additional constraints the user specified>

Trap warnings:
- <trap flag from critic pass, if any>
- <additional trap flags, if any>
- (none, if no traps were detected)

-------------------------------------------------------------
To create plans, run:
/mstack-plan-multi <paste the Goal and Constraints sections above>
```

### Multiple selections

If the user selects multiple ideas (e.g., A and C), generate a separate
handoff block for each. Do not merge them unless the user explicitly
asks for a combined approach (option D).

### Rules

- Do NOT invoke the Skill tool to call `/mstack-plan-multi`. The handoff
  is informational: print the argument, tell the user to run the command.
- Include all trap warnings from the critic pass in the handoff. These
  carry forward as constraints for plan-multi to address.
- Include the convergence signal if the selected idea was part of a
  multi-frame cluster; this context helps plan-multi gauge confidence.
