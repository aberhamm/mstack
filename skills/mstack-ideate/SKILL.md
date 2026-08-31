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

## Update check

Before any other work, run the shared, cooldown-aware check:

```bash
for _base in "${HOME}/.config/skillshare/skills" "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "${_base}/mstack-run" ] || continue
  _mstack_run="$(cd "${_base}/mstack-run" && pwd -P)"
  _mstack_root="$(cd "$_mstack_run/../.." && pwd -P)"
  bash "$_mstack_root/bin/mstack-update-check" 2>/dev/null || true
  break
done
```

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
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ ! -d "$REPO_ROOT/.mstack" ]; then
  bash "$SKILL_DIR/scripts/init.sh" bootstrap 2>&1
fi
```

## Step 1: Input parsing

Extract the problem statement from the user's input.

- If `$ARGUMENTS` is non-empty, use it directly as the problem statement.
- If empty, ask the user directly; use AskUserQuestion when the host provides it:
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
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
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

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
```

> **Read** `"$MSTACK_ROOT/skills/mstack-ideate/references/critic-and-traps.md"` before proceeding.

## Step 5: Cluster by approach

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
```

> **Read** `"$MSTACK_ROOT/skills/mstack-ideate/references/clustering.md"` before proceeding.

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

```bash
SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && SKILL_DIR="${_skill_base}/mstack-run"
done
MSTACK_ROOT="$(cd "$(cd "$SKILL_DIR" && pwd -P)/../.." && pwd)"
```

> **Read** `"$MSTACK_ROOT/skills/mstack-ideate/references/handoff.md"` before proceeding.
