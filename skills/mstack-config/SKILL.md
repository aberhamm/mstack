---
name: mstack-config
description: |
  Project settings for mstack. Initializes or edits .mstack/config.json.
  Configures health commands, scoring weights, review provider preferences,
  autonomy level, commit conventions, and ignored paths. Falls back to
  CLAUDE.md and built-in defaults when no config exists.
argument-hint: "[init | show | set <key> <value> | reset]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
---

You manage mstack project configuration. Settings live in
`.mstack/config.json` and affect how mstack-run, mstack-code-health,
mstack-code-review, and other skills behave.

User input:

```
$ARGUMENTS
```

## Storage

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CONFIG_FILE="$REPO_ROOT/.mstack/config.json"
```

The config file is in `.mstack/` which is gitignored. Settings are
local to each developer's checkout — they don't travel with the repo.

## Default config

When no config exists, mstack uses these defaults:

```json
{
  "health": {
    "commands": {},
    "weights": {
      "typecheck": 25,
      "lint": 20,
      "test": 30,
      "deadcode": 15,
      "shell": 10
    }
  },
  "review": {
    "provider": "auto"
  },
  "autonomy": "full",
  "commit": {
    "conventional": true,
    "trailer": true
  },
  "ignored_paths": []
}
```

## Config schema

### `health.commands`

Override auto-detection for specific tools:

```json
{
  "health": {
    "commands": {
      "typecheck": "pnpm -r typecheck",
      "lint": "pnpm -r lint",
      "test": "pnpm test",
      "deadcode": "npx knip",
      "shell": "shellcheck scripts/*.sh"
    }
  }
}
```

Empty string or `null` for a key means skip that tool. Omitted keys use
auto-detection.

### `health.weights`

Override default scoring weights. Must sum to 100:

```json
{
  "health": {
    "weights": {
      "typecheck": 30,
      "lint": 15,
      "test": 35,
      "deadcode": 10,
      "shell": 10
    }
  }
}
```

### `review.provider`

Control which external model to prefer for cross-model review:

- `"auto"` — discover best available (codex > gemini > claude-only)
- `"codex"` — always use Codex CLI if available
- `"gemini"` — always use Gemini CLI if available
- `"claude-only"` — never use external models

### `autonomy`

Default autonomy level for new plans (overridable per-plan in frontmatter):

- `"full"` — no stops, fully autonomous (default)
- `"checkpoint"` — pause after review for user approval before commit
- `"supervised"` — pause after implementation for user inspection

### `commit.conventional`

- `true` — use conventional commit format: `type(scope): subject` (default)
- `false` — plain commit messages

### `commit.trailer`

- `true` — add `Refs: docs/plans/<file>` trailer to commits (default)
- `false` — no trailers

### `ignored_paths`

Paths the worker should never edit, even if a plan references them:

```json
{
  "ignored_paths": [
    "db/migrations/",
    "vendor/",
    ".env*"
  ]
}
```

This supplements the hard rule about `db/migrations/` (which requires
`allows-migrations: true` in the plan).

## Modes

### `init` — create config with defaults

Create `.mstack/config.json` with the default values. If it already exists,
do nothing (use `reset` to overwrite).

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$REPO_ROOT/.mstack"
grep -q "^\.mstack/" "$REPO_ROOT/.gitignore" 2>/dev/null || echo ".mstack/" >> "$REPO_ROOT/.gitignore"
```

Write the default config and print: "Config initialized at .mstack/config.json"

### `show` — display current config

Read and pretty-print the current config. For each value, show whether it's
from config, CLAUDE.md, or the built-in default:

```
MSTACK CONFIG
=============
Source: .mstack/config.json

health.commands:
  typecheck:  pnpm -r typecheck  (config)
  lint:       pnpm -r lint       (config)
  test:       pnpm test          (config)
  deadcode:   npx knip           (auto-detected)
  shell:      shellcheck         (auto-detected)

health.weights:
  typecheck: 25  lint: 20  test: 30  deadcode: 15  shell: 10  (defaults)

review.provider:  auto (codex available, gemini unavailable)
autonomy:         full
commit:           conventional=true, trailer=true
ignored_paths:    db/migrations/, vendor/
```

### `set <key> <value>` — update a specific setting

Update a single config value using dot notation:

```
/mstack-config set review.provider codex
/mstack-config set autonomy checkpoint
/mstack-config set health.weights.test 40
/mstack-config set ignored_paths "db/migrations/,vendor/,.env*"
```

Read the existing config, update the specified key, and write back.
Validate the value:
- `autonomy` must be one of: full, checkpoint, supervised
- `review.provider` must be one of: auto, codex, gemini, claude-only
- `health.weights` values must be numbers that sum to 100
- `commit.conventional` and `commit.trailer` must be boolean

If validation fails, print the error and do not write.

### `reset` — restore defaults

Overwrite the config with default values. Confirm first:
"This will reset all mstack config to defaults. Current config will be lost."

### No argument — same as `show`

If called with no arguments, behave as `show`.

## Integration with other skills

Skills read config at startup:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CONFIG_FILE="$REPO_ROOT/.mstack/config.json"
if [ -f "$CONFIG_FILE" ]; then
  # Parse with jq if available, otherwise read with the Read tool
  cat "$CONFIG_FILE"
fi
```

If no config file exists, every skill falls back to its built-in defaults.
Config is optional — mstack works without it.
