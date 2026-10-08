---
name: mstack-config
description: |
  Project settings for mstack. Initializes or edits .mstack/config.json.
  Configures health commands, scoring weights, review provider preferences,
  commit conventions, and ignored paths. Falls back to
  AGENTS.md/CLAUDE.md and built-in defaults when no config exists.
argument-hint: "[init | show | set <key> <value> | reset | paperclip connect|status|reconnect|disable]"
allowed-tools: Bash Read
---

## Runtime paths and update check

Set `MSTACK_SKILL_FILE` to the absolute path of **this loaded SKILL.md**,
supplied by the harness. Substitute that path below; do not use the project
directory or assume a personal installation. Install the full MStack skill
set so `mstack-run` is a sibling. In each fresh Bash invocation, repeat this
bootstrap before using `skill_dir` or the variables it defines. Pass the
resolved paths to delegated agents explicitly.

```bash
MSTACK_SKILL_FILE="/absolute/path/to/mstack-config/SKILL.md"
MSTACK_RESOLVER="$(cd "$(dirname "$MSTACK_SKILL_FILE")/../mstack-run/scripts" && pwd)/install-paths.sh"
source "$MSTACK_RESOLVER"
SKILL_DIR="$(skill_dir mstack-run)" || exit 1
SCRIPTS_DIR="$SKILL_DIR/scripts"
mstack_update_check
```
You manage mstack project configuration. Settings live in
`.mstack/config.json` and affect how mstack-run, mstack-code-health,
mstack-code-review, and other skills behave.

User input:

```
$ARGUMENTS
```

## Scripts

All config read/write logic lives in `config.sh`. Resolve the scripts
directory:

```bash
SCRIPTS_DIR="$(skill_dir mstack-run)/scripts" || exit 1
```

### Available commands

| Command | What it does |
|---------|-------------|
| `bash "$SCRIPTS_DIR/config.sh" init` | Create config with defaults (no-op if exists) |
| `bash "$SCRIPTS_DIR/config.sh" show` | Pretty-print current config (or defaults) |
| `bash "$SCRIPTS_DIR/config.sh" get <dotpath>` | Get a single value (e.g., `health.weights.test`) |
| `bash "$SCRIPTS_DIR/config.sh" set <dotpath> <value>` | Set a single value with validation |
| `bash "$SCRIPTS_DIR/config.sh" reset` | Overwrite config with defaults |

The script validates values automatically:
- `review.provider` must be: auto, codex, gemini, claude-only
- `review.question_batch_size` must be: 1, 2, or 3
- `health.weights.*` must be numbers
- `commit.conventional` and `commit.trailer` must be true/false

## Modes

### `init`: create config with defaults

Run `bash "$SCRIPTS_DIR/config.sh" init`. Print: "Config initialized at
.mstack/config.json" (or note that it already exists).

### `show`: display current config (default when no argument)

Run `bash "$SCRIPTS_DIR/config.sh" show`. Present the JSON output to the
user. For each section, note whether values are from config or built-in
defaults:

```
MSTACK CONFIG
=============
Source: .mstack/config.json

health.commands:
  typecheck:  pnpm -r typecheck  (config)
  lint:       pnpm -r lint       (config)
  test:       pnpm test          (config)
  e2e:        (auto-detected)
  deadcode:   (auto-detected)
  shell:      (auto-detected)

health.weights:
  typecheck: 20  lint: 15  test: 25  e2e: 20  deadcode: 10  shell: 10  (defaults)

review.provider:  auto
review.question_batch_size: 3
commit:           conventional=true, trailer=true
ignored_paths:    (none)
```

### `set <key> <value>`: update a specific setting

Run `bash "$SCRIPTS_DIR/config.sh" set <key> <value>`. The script handles
validation and reports errors. Examples:

```
/mstack-config set review.provider codex
/mstack-config set review.question_batch_size 2
/mstack-config set health.weights.test 40
```

### `reset`: restore defaults

Confirm with the user first: "This will reset all mstack config to defaults.
Current config will be lost." Then run `bash "$SCRIPTS_DIR/config.sh" reset`.

## Paperclip commands

`/mstack-config paperclip connect` is an interactive setup flow. Helpers emit JSON
choices and never ask questions. Workers/headless callers return eligibility or
a diagnostic and defer connection to an interactive session.

1. Ask for the API URL and profile name (or let the user select an existing profile).
   An existing official CLI context may be suggested, never silently selected.
   Explain that localhost means this machine and a tailnet endpoint must be reachable
   from this client only when that affects the selected URL. Do not add personal defaults.
2. After explicit selection run `bash "$SCRIPTS_DIR/config.sh" paperclip profile
   --profile NAME --api-base URL --auth-file "$HOME/.paperclip/auth.json"`.
   This stores only the selected endpoint and credential-store reference. An existing
   shared profile cannot be retargeted; choose a new profile name for a different
   endpoint or credential-store reference so other repositories keep their connection.
3. Run `config.sh paperclip choices --profile NAME`. A valid existing official login
   is reused. For `authentication-missing` or `authentication-expired`, launch the
   official CLI using an argument array (no shell interpolation of user URL):
   `npx --yes paperclipai auth login --api-base URL --no-browser`.
   Show the official approval link, wait for the user's browser approval and command
   completion, then rerun choices. Never copy tokens, print the auth store, forge
   approval, or bypass login. `offline` asks the user to restore connectivity;
   `conflict` requires inspecting authorization. Never run login to fix an outage.
4. Present returned companies; after selection run `config.sh paperclip choices
   --profile NAME --company COMPANY_ID`. Present returned projects. If the user
   chooses to create a project, ask its name then run `config.sh paperclip create-project
   --profile NAME --company COMPANY_ID --name NAME --user-chose-create` exactly once.
   An uncertain creation requires inspecting the returned project list before any retry.
5. Save only after user selection: `config.sh paperclip connect --profile NAME
   --company COMPANY_ID --project PROJECT_ID`. The helper verifies authenticated
   company availability and project company membership before enabling. Show its actual
   state; never describe an offline or queued result as connected.

`/mstack-config paperclip status` runs `config.sh paperclip status` and displays
persistent mode separately from observed state (`connected`, `offline`,
`authentication-missing`, `authentication-expired`, `conflict`, `configuration-error`).
It preserves all settings and does not report event delivery; reporting status is
`paperclip.py status --repo PATH`.

`/mstack-config paperclip reconnect` runs `config.sh paperclip reconnect`. Missing or
expired credentials follow Step 3's official approval flow, then retry reconnect.
It validates the existing profile/company/project and never silently substitutes
another project. Failed or aborted reconnection leaves the binding unchanged.
An explicitly different binding requires disabling first and repeating connect.

`/mstack-config paperclip disable` runs `config.sh paperclip disable`. It retains
repository identity and project fields for an explicit later connect. Health,
review, hooks and `.mstack/config.json` are unchanged by these commands.

## Default config

When no config exists, mstack uses these defaults:

```json
{
  "health": {
    "commands": {},
    "weights": {
      "typecheck": 20,
      "lint": 15,
      "test": 25,
      "e2e": 20,
      "deadcode": 10,
      "shell": 10
    }
  },
  "review": {
    "provider": "auto",
    "question_batch_size": 3
  },
  "commit": {
    "conventional": true,
    "trailer": true
  },
  "ignored_paths": []
}
```

## Config schema reference

### `health.commands`: override tool auto-detection

Empty string or `null` for a key means skip that tool. Omitted keys use
auto-detection.

### `health.weights`: scoring weights (must sum to 100)

The six categories above are the complete set, and the block above is the ONLY
place default weights are defined: `health-check.sh` reads every weight through
`config.sh get health.weights.<category>` and carries no fallback literals of
its own. If a weight cannot be read the gate fails closed with
`FAILURES:config-unreadable` (exit 36) rather than scoring against an
improvised set.

Weights are relative, not absolute: a category with no detected tool is
`SKIPPED` and its weight is redistributed across the categories that did run.
A repo with no e2e framework is therefore scored out of 10 over the tools it
has, not capped at 8 for lacking Playwright.

### `review.provider`: cross-model review preference

- `"auto"`: discover best available (codex > gemini > claude-only)
- `"codex"`: always use Codex CLI if available
- `"gemini"`: always use Gemini CLI if available
- `"claude-only"`: never use external models

### `review.question_batch_size`: review decision pacing

- `3` (default): collect and present up to three independent review decisions
  at once; ask a follow-up batch only when an answer exposes a new decision.
- `2`: present two independent decisions at once.
- `1`: retain one-decision-at-a-time pacing.

Mstack passes this policy as invocation context to the external plan-review
skills it orchestrates. Decisions that depend on another answer, or irreversible
confirmations, remain separate regardless of this setting.

### `commit.conventional`: use `type(scope): subject` format

### `commit.trailer`: add a `Refs: <plans-dir>/<file>` trailer

### `ignored_paths`: paths the worker should never edit

Advisory, not enforced: `mstack-run` reads this list and instructs the worker to
leave those paths alone. No hook blocks a write to them.

## Integration with other skills

Skills read config via the script at startup:

```bash
bash "$SCRIPTS_DIR/config.sh" get review.provider
bash "$SCRIPTS_DIR/config.sh" get health.weights.test
```

If no config file exists, the script falls back to built-in defaults.
Config is optional; mstack works without it.
