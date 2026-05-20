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
---

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
SCRIPTS_DIR="${HOME}/.config/skillshare/skills/mstack-run/scripts"
[ -d "$SCRIPTS_DIR" ] || SCRIPTS_DIR="${HOME}/.claude/skills/mstack-run/scripts"
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
- `autonomy` must be: full, checkpoint, supervised
- `review.provider` must be: auto, codex, gemini, claude-only
- `health.weights.*` must be numbers
- `commit.conventional` and `commit.trailer` must be true/false

## Modes

### `init` — create config with defaults

Run `bash "$SCRIPTS_DIR/config.sh" init`. Print: "Config initialized at
.mstack/config.json" (or note that it already exists).

### `show` — display current config (default when no argument)

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
  deadcode:   (auto-detected)
  shell:      (auto-detected)

health.weights:
  typecheck: 25  lint: 20  test: 30  deadcode: 15  shell: 10  (defaults)

review.provider:  auto
autonomy:         full
commit:           conventional=true, trailer=true
ignored_paths:    (none)
```

### `set <key> <value>` — update a specific setting

Run `bash "$SCRIPTS_DIR/config.sh" set <key> <value>`. The script handles
validation and reports errors. Examples:

```
/mstack-config set review.provider codex
/mstack-config set autonomy checkpoint
/mstack-config set health.weights.test 40
```

### `reset` — restore defaults

Confirm with the user first: "This will reset all mstack config to defaults.
Current config will be lost." Then run `bash "$SCRIPTS_DIR/config.sh" reset`.

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

## Config schema reference

### `health.commands` — override tool auto-detection

Empty string or `null` for a key means skip that tool. Omitted keys use
auto-detection.

### `health.weights` — scoring weights (must sum to 100)

### `review.provider` — cross-model review preference

- `"auto"` — discover best available (codex > gemini > claude-only)
- `"codex"` — always use Codex CLI if available
- `"gemini"` — always use Gemini CLI if available
- `"claude-only"` — never use external models

### `autonomy` — default for new plans (overridable per-plan)

- `"full"` — no stops, fully autonomous
- `"checkpoint"` — pause after review for user approval before commit
- `"supervised"` — pause after implementation for user inspection

### `loop.max_iterations` — iteration cap per loop run

- `5` (default) — stop after 5 plans, run simplify pass, notify
- `0` — unlimited, run until backlog is clear
- Any positive integer — custom cap

### `commit.conventional` — use `type(scope): subject` format

### `commit.trailer` — add `Refs: docs/plans/<file>` trailer

### `ignored_paths` — paths the worker should never edit

## Integration with other skills

Skills read config via the script at startup:

```bash
bash "$SCRIPTS_DIR/config.sh" get autonomy
bash "$SCRIPTS_DIR/config.sh" get health.weights.test
```

If no config file exists, the script falls back to built-in defaults.
Config is optional — mstack works without it.
