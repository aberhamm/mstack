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

Build the prompt with the filesystem boundary and the breakdown.

**The `mktemp` template must END in `X`s — do not add a `.txt` suffix.** BSD/macOS
`mktemp` rejects trailing characters after the `X`s and fails with the misleading
`mkstemp failed: File exists`, aborting the critique before codex ever runs. GNU
`mktemp` tolerates it, so this breaks only on macOS.

```bash
TMPERR=$(mktemp "${TMPDIR:-/tmp}/codex-plan-err-XXXXXX")
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

- If either flags real issues, revise the breakdown to address them
  before presenting to the user.
- If they contradict each other, use your judgment. Include a note
  in Step 4 about the disagreement so the user can weigh in.
- If **both say the breakdown is solid**, do not proceed as-is — see the
  no-tension convention below.

#### Both clear is a smell, not a confirmation (Rule 4, plan 090)

Two channels handed the same framing produce independence of *style*, not
independence of *attention*. On the batch this convention comes from, the
cross-model channel reported "No tension — Codex sharpened two review findings
rather than disputing them", and the batch shipped two P1 defects anyway. A
unanimous all-clear across a **multi-plan breakdown** is therefore evidence
about the brief, not about the decomposition: the likeliest explanation is not
that every plan is simultaneously flawless, it is that both reviewers read with
the plan's own framing.

Gate the convention on Rule 4's toggle and say which mode is in play (resolve
`RUN_SKILL_DIR` here — plan-multi does not resolve it anywhere else):

```bash
RUN_SKILL_DIR="${HOME}/.config/skillshare/skills/mstack-run"
for _skill_base in "${HOME}/.agents/skills" "${HOME}/.codex/skills" "${HOME}/.claude/skills"; do
  [ -d "$RUN_SKILL_DIR" ] && break
  [ -d "${_skill_base}/mstack-run" ] && RUN_SKILL_DIR="${_skill_base}/mstack-run"
done

if bash -c '. "$1/scripts/lib.sh"; rule_mode_line premise_brief' _ "$RUN_SKILL_DIR"; then
  PREMISE_BRIEF=on
else
  PREMISE_BRIEF=off
fi
```

With `PREMISE_BRIEF=off`, this convention does not apply: use the **pre-090
synthesis** — both clear, proceed to Step 4 as-is — and note `structural
critique: rule premise_brief disabled — pre-090 synthesis, no premise re-ask`.

With `PREMISE_BRIEF=on`, a both-clear result across two or more plans costs
**exactly one premise-directed re-ask**, sent to whichever channel is available
(prefer codex):

```
Both critiques cleared this breakdown. That is the state I distrust most, so do
not re-check the structure and do not sharpen what the other reviewer said.
Attack the breakdown's PREMISES instead — the things it treats as already true
about this codebase and about what each plan will produce. Prioritize: (a) any
factual claim about existing code that cites nothing; (b) every "should /
presumably / by construction / obviously" sentence; (c) any premise whose
failure would invalidate a whole plan rather than a detail. If the premises
hold, say so in one line — do not manufacture tension.
```

One re-ask, once per breakdown — a smell check, not a loop. **If it is skipped
(no channel available, or the user declines), say so explicitly in the Step 4
note.** A "both clear" with neither a re-ask result nor a recorded skip is not a
legal synthesis state; unstated silence there is exactly the false clearance this
convention exists to remove:

```
Structural critique: Codex + secondary reviewer (both clear) — premise re-ask: no new findings
Structural critique: Codex + secondary reviewer (both clear) — premise re-ask SKIPPED (no external model available)
```

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
