# Harness compatibility

Native skill discovery does not prove MStack execution compatibility. Before
execution, establish which harness is running, whether a worker can edit and
run Bash, and whether independent reviewers can run below that worker. Use
the actual session tools and settings; do not infer capabilities from model
names, installed files, or the editor brand. When capability is uncertain,
run a bounded, read-only delegation probe and inspect its returned result.
Unknown or failed delegation stops execution before plan mutation.

## Codex

Use `mstack-worker` if installed, otherwise an explicit worker with the full
brief. The session must expose subagent tools and permit enough depth for
worker-to-reviewer delegation. The parent owns commits and parses the result.
Use `$mstack-run` or the skill selector. A goal driver is optional and
harness-specific; single-plan execution does not require one.

## Claude Code

Use `Agent` for the worker with a self-contained brief. Verify the worker has
`Agent` available for independent reviewers and that the configured spawn-depth
limit permits the required layers. Older clients or restricted sessions may
not support this topology. Invoke `/mstack-run` for a single plan.

## Copilot in VS Code Local — experimental MStack support

Install the VS Code adapters into the consumer project's `.github/agents/`.
Use a Local session in Agent mode with file, terminal, and
`agent/runSubagent` tools enabled. Enable
`chat.subagents.allowInvocationsFromSubagents` for the worker's reviewers
(off by default). Each invocation is stateless and lacks the parent's chat
history; include all constraints, plan contents, resolved paths, and the exact
result schema. Do not rely on follow-up messages to a running worker.

Before the first implementation in a session, have `mstack-worker` delegate
a read-only probe to `mstack-reviewer` and return its findings. Confirm both
delegations actually appear in the tool trace. A textual claim is insufficient.
The probe must not write files, run reviews that record verdicts, or commit.
If nested delegation is unavailable, stop. A different orchestration topology
would need its own implementation and validation.

## Copilot in Visual Studio — execution unverified

Visual Studio 2026 18.5+ discovers skills. Custom agents use different tool
names from VS Code and can be selected or mentioned, but that does not verify
isolated worker-to-reviewer delegation. The Visual Studio adapters are role
templates for supervised use, not an autonomous execution adapter. Until a
supported delegation mechanism is verified, do not run `mstack-run` here.
Planning and status remain experimental; stop any workflow phase that needs
unavailable delegation instead of collapsing it into one agent.

## Other harnesses

Cursor, Gemini CLI, Copilot CLI, and remote/cloud sessions are not validated
MStack execution targets. Skill synchronization alone does not promote them.
Do not assume Local VS Code settings or tools apply to another harness.

## Tool metadata

The skill `allowed-tools` strings retain Claude tool names for Claude Code.
They neither grant permissions nor define equivalent tools on another host.
Use the active harness's tools and adapter tool lists. Only named review
skills record verdicts; an adapter persona does not authorize gate changes.

## Official references (checked 2026-10-08)

- [VS Code skills](https://code.visualstudio.com/docs/agent-customization/agent-skills)
- [VS Code subagents](https://code.visualstudio.com/docs/agents/run/subagents)
- [VS Code custom agents](https://code.visualstudio.com/docs/agent-customization/custom-agents)
- [Visual Studio skills](https://learn.microsoft.com/en-us/visualstudio/ide/copilot-agent-skills?view=visualstudio)
- [Visual Studio custom agents](https://learn.microsoft.com/en-us/visualstudio/ide/copilot-specialized-agents?view=visualstudio)
- [Codex skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents)
