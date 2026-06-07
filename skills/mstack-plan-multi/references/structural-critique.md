## Step 3.5: Multi-model structural critique

After designing the breakdown but before presenting it, fan out to
available external models for blind structural critique. This catches
decomposition blind spots that a single model misses. The critique is
on the plan structure (scope, ordering, dependencies, gaps), not on
format or implementation details. Plan-doctor handles those later.

### Discovery

```bash
command -v codex >/dev/null 2>&1 && echo "CODEX: available" || echo "CODEX: unavailable"
```

Two critique channels, run in parallel when available:

1. **Codex** (if binary exists): shell out to `codex exec`
2. **Secondary agent perspective**: spawn a reviewer subagent when the host
   supports subagents. In Claude Code, use the Agent tool with `model:
   "sonnet"` when available. In Codex, spawn a reviewer subagent (prefer the
   `mstack-reviewer` custom agent if present).

If Codex is unavailable, the secondary agent still runs (a single external
perspective is still valuable). If neither is available (no codex binary,
subagent spawn fails), skip this step and proceed to Step 4.

### Codex critique (if available)

Build the prompt with the filesystem boundary and the breakdown:

```bash
TMPERR=$(mktemp "${TMPDIR:-/tmp}/codex-plan-err-XXXXXX.txt")
codex exec --sandbox read-only -c 'model_reasoning_effort="high"' "IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, ~/.codex/skills/, .claude/skills/, .agents/skills/, or agents/. Stay focused on repository code only.

You are reviewing a plan decomposition for autonomous AI execution. The goal and proposed breakdown are below. Your job is to find structural problems only:

- Missing plans: are there gaps where one plan's output doesn't connect to the next plan's input?
- Wrong dependencies: are any blocked-by edges missing or incorrect? Would any plan fail because something it needs hasn't been built yet?
- Scope problems: are any plans too large for a single autonomous execution (more than 3 hours of focused work)? Are any too trivially small?
- Unstated assumptions: does any plan assume something that isn't produced by an earlier plan or isn't already in the codebase?
- Ordering risks: should any plan be earlier because it de-risks the rest?

Do not critique formatting, naming, or implementation approach. Only structural decomposition issues.

GOAL: <the user's goal>

PROPOSED BREAKDOWN:
<the plan breakdown table from Step 3>

Report only real problems. If the breakdown is solid, say so in one line." \
  < /dev/null 2>"$TMPERR"
```

Use `timeout: 300000` on the Bash call.

### Secondary agent critique

Spawn one reviewer subagent with the same structural focus:

```
prompt: "You are reviewing a plan decomposition for autonomous AI execution.
The user's goal is: <goal>

The proposed breakdown is:
<the plan breakdown table from Step 3>

The codebase is: <project name, key files, structure summary from Step 2>

Find structural problems only:
- Missing plans or gaps between plans
- Wrong or missing dependency edges
- Plans too large or too small for autonomous execution
- Unstated assumptions not covered by earlier plans or the existing codebase
- Ordering risks (should something be earlier to de-risk?)

Do not critique formatting, naming, or implementation approach. Only
structural decomposition issues. If the breakdown is solid, say so in
one line. Be direct, be specific, name which plan numbers are affected."
```

Host-specific guidance:
- Claude Code: use the Agent tool with `model: "sonnet"` when available.
- Codex: spawn the `mstack-reviewer` custom agent if present, otherwise spawn
  one default reviewer subagent and wait for its response.

### Synthesize

After both return, review their feedback:

- If both say the breakdown is solid, proceed to Step 4 as-is.
- If either flags real issues, revise the breakdown to address them
  before presenting to the user.
- If they contradict each other, use your judgment. Include a note
  in Step 4 about the disagreement so the user can weigh in.

In the Step 4 presentation, add a one-line note below the breakdown
table showing what was critiqued and by whom:

```
Structural critique: Codex + secondary reviewer (both clear)
```

or

```
Structural critique: Codex flagged missing migration plan between 002 and 003.
Secondary reviewer flagged plan 005 scope too large. Both addressed in revised breakdown.
```

If critique was skipped (no external models available), note:

```
Structural critique: skipped (no external models available)
```
