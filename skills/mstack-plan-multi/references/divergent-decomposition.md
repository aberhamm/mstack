### Step 3a: Divergent decomposition (Explore mode)

When the user chooses Explore, generate 3 independent candidate decompositions under
different architectural frames, score them, and present the best one with notable
alternatives.

#### 3a.1: Read decomposition frames

Resolve and read the decomposition frame definitions:

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
FRAMES_FILE="$MSTACK_ROOT/skills/mstack-shared/cognitive-frames.md"
cat "$FRAMES_FILE"
```

If the frames file is not found, use the inline definitions below directly.
Use the three decomposition frames defined there:

1. **Minimize Coupling** -- each plan touches one module, explicit data contracts, no implicit dependencies
2. **Maximize Parallelism** -- minimize the critical path, fan-out over serial chains, split to enable concurrency
3. **Simplest Thing That Works** -- one verifiable outcome per plan, no bundled features, minimal scope per plan

#### 3a.2: Generate 3 independent candidates

For each decomposition frame, generate a complete plan breakdown independently.
Each candidate must meet the same quality bar as single-pass mode:

- Plan list with titles, 1-sentence descriptions, dependency relationships
- Execution order (which plans run in parallel vs. sequential)
- Review assignments (which plans need ceo/eng/design review and why)
- DAG structure with explicit blocked-by edges

**Independence requirement:** Generate each candidate in a separate agent call to ensure
independence. Each agent receives only the goal description, the codebase research from
Step 2, and its assigned decomposition frame. No agent has visibility into other
candidates' output. This prevents anchoring bias where later candidates converge toward
the first.

Agent prompt template for each candidate:

```
You are decomposing a goal into an ordered backlog of implementation plans.
Use the following decomposition frame to guide your architectural decisions:

FRAME: <frame name>
<frame checklist and behavioral bias from cognitive-frames.md>

GOAL: <the user's goal from Step 1>

CODEBASE CONTEXT: <summary from Step 2: project structure, existing code, conventions>

EXISTING PLANS: <any existing plans that must not be duplicated>

Produce a complete plan breakdown as a DAG:
- Each plan: number, title, 1-sentence description, blocked-by list, review type
- Plans should be 1-3 hours of focused work each
- Plans must be independently shippable (no broken intermediate states)
- Front-load hard decisions (schema, API contracts, architecture)

Output the breakdown as a numbered list with blocked-by edges and review assignments.
```

#### 3a.3: Critic scoring

After all 3 candidates return, score each candidate on 4 axes (1-10 scale):

| Axis | What it measures | Better = |
|------|-----------------|----------|
| **Dependency depth** | Longest chain in the DAG | Shallower (fewer sequential hops) |
| **Parallelism potential** | Number of plans that can run concurrently at peak | More concurrent plans |
| **Scope-fit per plan** | How well each plan fits the 1-3 hour sweet spot | All plans in range, none too large or trivially small |
| **Risk distribution** | Whether critical decisions are spread across plans or concentrated | More distributed (no single plan is a chokepoint for judgment calls) |

Sum the 4 scores for each candidate. The highest-scoring candidate wins.
In case of a tie, prefer the candidate with the shallowest dependency depth
(most parallelizable).

#### 3a.4: Reconciliation validation

Take the winning candidate and validate before presenting:

1. **No circular dependencies:** Walk the DAG and confirm no plan transitively
   depends on itself. If cycles exist, break them by reordering or splitting.
2. **No scope gaps:** Map every acceptance criterion from the user's goal to at
   least one plan. If any criterion is uncovered, add a plan or expand an existing one.
3. **No conflicting assumptions:** Check that no two plans assume contradictory
   things about shared resources (same file modified differently, conflicting schema
   choices, incompatible API designs). If conflicts exist, resolve by adding an
   explicit contract plan early in the DAG.
4. **Stable plan ordering:** If the critic scoring suggests a different sequencing
   than the candidate proposed (e.g., a plan scored high on risk should be earlier),
   reorder accordingly.

#### 3a.5: Notable alternatives

After reconciliation, prepare a "Notable alternatives" section that highlights
key structural differences from the non-winning candidates. This goes into the
Step 4 presentation. Format:

```
Notable alternatives (from other decompositions):
  - Candidate B (<frame name>) proposed <key difference>, which <tradeoff>
  - Candidate C (<frame name>) proposed <key difference>, which <tradeoff>
```

Include only differences that represent genuine architectural alternatives the user
might want to revisit, not minor ordering variations.

After completing 3a.5, proceed to Step 3.5 (multi-model structural critique) with
the winning candidate as the breakdown.
