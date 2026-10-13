# Host UI question routing

Use the current host's interactive question tool for MStack questions whenever
it is available and permitted for the specific interaction. Do not ask the user
to type option letters in chat just because Claude's `AskUserQuestion` is absent.
Inspect the tools exposed to this session and their schemas; names below are
mapping hints, not permission to call unavailable tools or invented aliases.

| Host | Question interface |
|---|---|
| Claude Code | `AskUserQuestion` |
| Codex | `request_user_input_async` when exposed; otherwise `request_user_input` when available and allowed in the current mode |
| GitHub Copilot in VS Code | `vscode/askQuestions` (use the actual callable name exposed by the client) |
| GitHub Copilot CLI | `ask_user` when enabled in an interactive session |
| GitHub Copilot in Visual Studio / other clients | Use the exposed interactive question tool, if any; do not assume VS Code or CLI tool names apply |
| OpenCode | `question` when enabled |
| Pi coding agent | An installed extension's model-callable question tool, if exposed; extension UI APIs alone are not model tools |

For Pi, extensions can provide UI dialogs through `ctx.ui`. A skill cannot call
those APIs directly. If no installed extension exposes a question tool, use the
chat fallback. Do not install an extension or change host settings just to ask a
question. This routing supports existing capabilities; it does not certify the
host's complete MStack execution/delegation workflow.

## Preserve the decision, adapt the shape

- Offer concise, concrete choices, with the recommendation first. Follow the
  tool's limits for question count, option count, labels, and free-text answers.
- Batch independent decisions in a multi-question call when supported. If the
  tool supports only one question, use the UI for each decision. Count decisions,
  not tool calls, against the skill's question budget; do not add decisions when
  splitting a batch.
- Use native multi-select when available. If unavailable, represent the allowed
  selections as explicit choices or one include/exclude UI question per item
  within the existing budget. If that cannot express the required selection
  within the budget, use one numbered chat selection for that interaction.
  Never silently drop findings or treat single-select as multi-select.
- Keep required approvals separate from optional preferences. Respect host
  restrictions: a tool allowed only for clarification must not carry a commit,
  deletion, publishing, or session-close approval. Use the host's permitted
  approval mechanism or ask explicitly in chat when no suitable UI exists.
- For asynchronous tools, continue independent work while the answer is pending.
  Do not proceed with work that requires that answer. A preselected choice,
  timeout, dismissal, or missing response is not authorization. For optional
  preferences only, follow the host's no-answer policy.
- Headless/autonomous policy still applies. Do not summon an interactive UI in a
  non-interactive run; follow the invoking skill's configured headless policy.

Use plain numbered chat only when no exposed UI tool can handle the interaction,
including disabled tools, mode restrictions, or unsupported selection shape.
Briefly state the concrete limitation; never claim Codex lacks UI questions
merely because it lacks `AskUserQuestion`.

When delegating a review that will ask questions, pass the resolved path of this
reference and instruct the reviewer to read it before asking. Existing user
authorization remains valid; this routing adds no new approval requirement.

## Source evidence

Mappings checked 2026-10-13. Runtime tool descriptions are authoritative for
Codex availability and restrictions, which vary by session and mode.

- [Copilot VS Code tools](https://code.visualstudio.com/docs/agents/reference/tools-reference)
- [Copilot CLI tools](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
- [OpenCode question tool](https://docs.opencode.ai/docs/tools/#question)
- [Pi extension tools and UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
