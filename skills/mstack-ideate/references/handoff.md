## Step 7: Handoff to plan-multi

After presenting the ranked results, offer the user a structured handoff
to `/mstack-plan-multi`.

### Idea selection

Ask the user which idea(s) to develop into plans; use AskUserQuestion when the
host provides it:

```
Ready to plan? Select idea(s) to hand off to /mstack-plan-multi:

A) #1: <top idea title>
B) #2: <second idea title>
C) #3: <third idea title>
D) Custom: combine elements from multiple ideas
E) None: save results for later with /mstack-stash
```

If the user selects "E" or declines, suggest `/mstack-stash` and stop.
If the user selects "D", ask a follow-up question for which elements
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

- Do NOT automatically invoke `mstack-plan-multi`. The handoff is
  informational: print the argument, tell the user to run the command.
- Include all trap warnings from the critic pass in the handoff. These
  carry forward as constraints for plan-multi to address.
- Include the convergence signal if the selected idea was part of a
  multi-frame cluster; this context helps plan-multi gauge confidence.
