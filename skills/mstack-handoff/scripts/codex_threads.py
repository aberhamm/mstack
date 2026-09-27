#!/usr/bin/env python3
"""codex_threads.py — read-only Codex thread lister and rollout extractor.

Backs the mstack-handoff "from codex" mode: reconstructing an mstack
handoff checkpoint from a Codex CLI rollout on disk when Codex itself
cannot write its own handoff (e.g. it is out of credits).

NEVER writes anything under ~/.codex. Both subcommands are read-only
against the Codex thread index (a sqlite db, opened read-only via a
`file:...?mode=ro` URI) and rollout JSONL files (streamed line by line,
never loaded fully into memory).

Stdlib only, Python 3.

Usage:
  codex_threads.py list [--cwd DIR] [--limit N] [--all-sources]
                         [--include-archived] [--json]
  codex_threads.py extract <thread-id-or-prefix-or-rollout-path>
                            [--max-chars N] [--out FILE]

Environment overrides (mainly for tests / non-default installs):
  MSTACK_CODEX_STATE_DB   path to the thread index sqlite db
                           (default: ~/.codex/state_5.sqlite)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime

DEFAULT_DB = os.path.expanduser("~/.codex/state_5.sqlite")

# threads.source: real, user-driven threads are one of these three. Anything
# else (a JSON-object string such as {"subagent":{"other":"guardian"}} or
# {"subagent":{"thread_spawn":...}}) is an approval-reviewer or spawned
# subagent thread and is excluded by default.
REAL_SOURCES = ("vscode", "cli", "exec")

# response_item / message role=user texts that begin with one of these are
# harness-injected context, not something the user typed.
INJECTED_PREFIXES = (
    "<environment_context>",
    "<recommended_plugins>",
    "<user_instructions>",
    "# AGENTS.md",
    "<app-context>",
    "<permissions",
    "<turn_aborted>",
)

# A bare, very long token with no whitespace is almost always an encrypted
# or opaque blob (Codex reasoning is encrypted; inter-agent messages are
# Fernet-style tokens). Redact rather than let it eat the char budget.
_OPAQUE_RE = re.compile(r"^[A-Za-z0-9_\-+/=]{200,}$")

DEFAULT_MAX_CHARS = 150_000
ASSISTANT_CAP = 4_000
CMD_OUTPUT_CAP_NORMAL = 2_000
CMD_OUTPUT_CAP_ERROR = 6_000
CMD_TEXT_CAP = 3_000
PROTECT_RECENT_ITEMS = 20

_ERROR_SIGNALS = (
    "Traceback (most recent call last)",
    "Error:",
    "error:",
    "ERROR",
    "FAILED",
    "Fatal",
    "fatal:",
    "Exception",
    "Permission denied",
    "No such file or directory",
    "command not found",
    "non-zero exit",
    "exit code 1",
    "exit status 1",
)

# apply_patch headers: reliable regardless of surrounding noise, because
# they are anchored to the start of a line. Applied to the FULL raw call
# text (a JS wrapper's own boilerplate never happens to start a line with
# "*** Update/Add/Delete File: ").
_PATCH_HEADER_RE = re.compile(r"^\*\*\* (?:Update|Add|Delete) File: (.+)$", re.MULTILINE)

# Shell write patterns: only safe to run against a CLEANLY extracted shell
# command, never the raw JS wrapper text — the wrapper's own boilerplate
# (`}); text(r.output);`) contains '>' -free but paren/brace noise that a
# permissive path regex would otherwise swallow.
_SHELL_WRITE_REGEXES = [
    re.compile(r">>?\s*([^\s|&;<>]+)"),
    re.compile(r"\btee\s+(?:-a\s+)?([^\s|&;]+)"),
    re.compile(r"\b(?:mv|cp)\s+(?:-\w+\s+)*\S+\s+([^\s|&;]+)"),
    re.compile(r"\bgit\s+mv\s+\S+\s+([^\s|&;]+)"),
]
_WRITE_IGNORE = {"/dev/null", "&1", "&2", "&-", "-"}


def _clean_path_candidate(raw: str):
    path = raw.strip().strip("'\"")
    if not path or path in _WRITE_IGNORE or path.startswith("-"):
        return None
    if "/" not in path and "." not in path:
        return None
    return path


# --------------------------------------------------------------------------
# DB access
# --------------------------------------------------------------------------

def db_path() -> str:
    return os.environ.get("MSTACK_CODEX_STATE_DB") or DEFAULT_DB


def connect_ro(path: str) -> sqlite3.Connection:
    if not os.path.isfile(path):
        raise SystemExit(f"codex_threads: state db not found: {path}")
    uri = "file:" + os.path.abspath(path) + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


THREAD_COLUMNS = (
    "id", "rollout_path", "cwd", "title", "name", "first_user_message",
    "source", "archived", "updated_at_ms", "updated_at", "tokens_used",
    "git_branch",
)


def fetch_all_threads(con: sqlite3.Connection):
    cur = con.execute(f"SELECT {', '.join(THREAD_COLUMNS)} FROM threads")
    return [dict(zip(THREAD_COLUMNS, row)) for row in cur.fetchall()]


def fetch_thread_by_id(con: sqlite3.Connection, thread_id: str):
    cur = con.execute(
        f"SELECT {', '.join(THREAD_COLUMNS)} FROM threads WHERE id = ?",
        (thread_id,),
    )
    row = cur.fetchone()
    return dict(zip(THREAD_COLUMNS, row)) if row else None


def fetch_threads_by_prefix(con: sqlite3.Connection, prefix: str):
    cur = con.execute(
        f"SELECT {', '.join(THREAD_COLUMNS)} FROM threads WHERE id LIKE ? "
        "ORDER BY id",
        (prefix + "%",),
    )
    return [dict(zip(THREAD_COLUMNS, row)) for row in cur.fetchall()]


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

def is_real_source(source) -> bool:
    return isinstance(source, str) and source in REAL_SOURCES


def _truthy(value) -> bool:
    """SQLite (and ad-hoc test fixtures) can hand back "0"/"" for a boolean
    column depending on declared column affinity. bool("0") is True in
    Python, which would silently include archived threads by default, so
    every boolean-ish DB flag in this module goes through this helper
    instead of a bare truthiness check."""
    if value in (None, "", 0, "0", False):
        return False
    return bool(value)


def effective_updated_ms(row: dict) -> int:
    ms = row.get("updated_at_ms") or 0
    try:
        ms = int(ms)
    except (TypeError, ValueError):
        ms = 0
    if ms:
        return ms
    secs = row.get("updated_at") or 0
    try:
        return int(secs) * 1000
    except (TypeError, ValueError):
        return 0


def display_title(row: dict) -> str:
    for key in ("name", "title", "first_user_message"):
        val = (row.get(key) or "").strip()
        if val:
            return val
    return "(untitled)"


def one_line(text: str, limit: int) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) > limit:
        return collapsed[: limit - 1] + "…"
    return collapsed


def short_id(thread_id: str) -> str:
    return thread_id[:12]


def cwd_matches(thread_cwd, target: str) -> bool:
    if not thread_cwd:
        return False
    target = target.rstrip("/") or "/"
    return thread_cwd == target or thread_cwd.startswith(target + "/")


def fmt_ts_ms(ms: int) -> str:
    if not ms:
        return "unknown"
    try:
        return datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "unknown"


# --------------------------------------------------------------------------
# list
# --------------------------------------------------------------------------

def cmd_list(args) -> int:
    target_cwd = os.path.abspath(args.cwd) if args.cwd else os.getcwd()
    con = connect_ro(db_path())
    try:
        rows = fetch_all_threads(con)
    finally:
        con.close()

    filtered = []
    for row in rows:
        if not args.all_sources and not is_real_source(row.get("source")):
            continue
        if not args.include_archived and _truthy(row.get("archived")):
            continue
        if not cwd_matches(row.get("cwd"), target_cwd):
            continue
        filtered.append(row)

    filtered.sort(key=effective_updated_ms, reverse=True)
    if args.limit:
        filtered = filtered[: args.limit]

    if args.json:
        out = []
        for row in filtered:
            out.append({
                "id": row["id"],
                "short_id": short_id(row["id"]),
                "cwd": row.get("cwd"),
                "title": display_title(row),
                "name": row.get("name"),
                "raw_title": row.get("title"),
                "first_user_message": row.get("first_user_message"),
                "source": row.get("source"),
                "archived": _truthy(row.get("archived")),
                "updated_at_ms": effective_updated_ms(row),
                "tokens_used": int(row.get("tokens_used") or 0),
                "git_branch": row.get("git_branch"),
                "rollout_path": row.get("rollout_path"),
            })
        print(json.dumps(out, indent=2))
        return 0

    if not filtered:
        print(f"No Codex threads found for cwd {target_cwd}")
        return 0

    print(f"Codex threads for {target_cwd} (newest first, {len(filtered)} shown):")
    print()
    for row in filtered:
        title = one_line(display_title(row), 88)
        flag = " [archived]" if _truthy(row.get("archived")) else ""
        tokens = int(row.get("tokens_used") or 0)
        print(
            f"  {short_id(row['id'])}  {fmt_ts_ms(effective_updated_ms(row))}  "
            f"tok={tokens:<9}{title}{flag}"
        )
    return 0


# --------------------------------------------------------------------------
# extract — rollout parsing
# --------------------------------------------------------------------------

def _texts(content, kinds=("input_text", "output_text", "text")):
    out = []
    for part in content or []:
        if isinstance(part, dict) and part.get("type") in kinds and part.get("text"):
            out.append(part["text"])
    return out


def _redact(value: str) -> str:
    if isinstance(value, str) and _OPAQUE_RE.match(value):
        return f"[opaque/encrypted content omitted, {len(value)} chars]"
    return value


def _redact_args(args):
    if isinstance(args, dict):
        return {k: _redact(v) if isinstance(v, str) else v for k, v in args.items()}
    if isinstance(args, str):
        return _redact(args)
    return args


def _is_injected(text: str) -> bool:
    return text.lstrip().startswith(INJECTED_PREFIXES)


def _output_text(output) -> str:
    if output is None:
        return ""
    if isinstance(output, str):
        try:
            parsed = json.loads(output)
            if isinstance(parsed, dict) and "output" in parsed:
                return str(parsed["output"])
        except (ValueError, TypeError):
            pass
        return output
    if isinstance(output, list):
        return "\n".join(_texts(output))
    try:
        return json.dumps(output)
    except TypeError:
        return str(output)


# Codex's "exec" custom_tool_call wraps a shell command in a small JS
# snippet. The key has been observed both unquoted (JS shorthand,
# `{cmd:"..."}`) and quoted (`{"cmd":"..."}`) across calls in the same
# rollout, so both are accepted.
_EXEC_CMD_RE = re.compile(r'tools\.exec_command\(\{"?cmd"?\s*:\s*(".*?(?<!\\)")', re.S)
# Fallback label for an "exec" call whose JS wrapper isn't exec_command at
# all (tools.web__run(...), an apply_patch built from a JS string, etc).
_JS_CALL_RE = re.compile(r"tools\.(\w+)\(")


def _extract_call(payload: dict, ptype: str):
    """Returns (label, display_body, raw_text_for_file_detection)."""
    name = payload.get("name") or "unknown"
    if ptype == "custom_tool_call":
        raw = payload.get("input") or ""
        if name == "exec":
            m = _EXEC_CMD_RE.search(raw)
            if m:
                try:
                    return "$", json.loads(m.group(1)), raw
                except (ValueError, TypeError):
                    pass
            # Not a plain shell command — e.g. tools.web__run(...), or an
            # apply_patch built from a JS string constant. Still worth
            # showing (truncated); file detection scans the raw text below
            # regardless, so apply_patch headers are still picked up.
            fn = _JS_CALL_RE.search(raw)
            label = f"exec (raw js: {fn.group(1)})" if fn else "exec (raw)"
            return label, _redact(raw), raw
        return name, _redact(raw), raw

    # function_call
    args_raw = payload.get("arguments") or "{}"
    try:
        args = json.loads(args_raw)
    except (ValueError, TypeError):
        args = {"raw": args_raw}
    if name in ("shell", "exec_command", "local_shell"):
        cmd = None
        if isinstance(args, dict):
            cmd = args.get("cmd") or args.get("command")
        if isinstance(cmd, list):
            cmd = " ".join(str(c) for c in cmd)
        if cmd:
            return "$", cmd, args_raw
    args = _redact_args(args)
    try:
        body = json.dumps(args, ensure_ascii=False)
    except TypeError:
        body = str(args)
    return f"call {name}", body, args_raw


def _looks_like_error(text: str) -> bool:
    return any(sig in text for sig in _ERROR_SIGNALS)


def _collect_patch_files(raw_text: str, files: set) -> None:
    if not raw_text:
        return
    # apply_patch headers inside a Codex "exec" JS wrapper carry the JS
    # string's own literal backslash-n escapes rather than real newlines
    # (the surrounding JSON layer has already been decoded by this point),
    # so normalize those to real newlines before the MULTILINE header regex
    # runs, or "*** Add File: ..." never starts its own line.
    normalized = raw_text.replace("\\n", "\n")
    for m in _PATCH_HEADER_RE.finditer(normalized):
        path = _clean_path_candidate(m.group(1))
        if path:
            files.add(path)


def _collect_shell_write_files(cmd_text, files: set) -> None:
    if not isinstance(cmd_text, str) or not cmd_text:
        return
    for rx in _SHELL_WRITE_REGEXES:
        for m in rx.finditer(cmd_text):
            path = _clean_path_candidate(m.group(1))
            if path:
                files.add(path)


def parse_rollout(path: str):
    """Stream a rollout JSONL file. Returns (meta, items, files_seen)."""
    meta = {"cwd": None, "branch": None, "thread_id": None, "cli_version": None,
            "first_ts": None, "last_ts": None}
    items = []  # chronological list of dicts
    pending = {}  # call_id -> {"label", "body", "ts"}
    files_seen: set = set()

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except (ValueError, TypeError):
                continue
            if not isinstance(rec, dict):
                continue

            rtype = rec.get("type")
            ts = rec.get("timestamp")
            if ts:
                if meta["first_ts"] is None:
                    meta["first_ts"] = ts
                meta["last_ts"] = ts

            payload = rec.get("payload")
            payload = payload if isinstance(payload, dict) else {}

            if rtype == "session_meta":
                meta["cwd"] = payload.get("cwd") or meta["cwd"]
                git = payload.get("git") or {}
                meta["branch"] = git.get("branch") or payload.get("git_branch") or meta["branch"]
                meta["thread_id"] = payload.get("id") or payload.get("session_id") or meta["thread_id"]
                meta["cli_version"] = payload.get("cli_version") or meta["cli_version"]
                continue

            if rtype == "compacted":
                msg = (payload.get("message") or "").strip()
                if not msg:
                    hist = payload.get("replacement_history") or []
                    user_texts = []
                    for h in hist:
                        if isinstance(h, dict) and h.get("role") == "user":
                            user_texts.extend(_texts(h.get("content")))
                    if user_texts:
                        preview = " | ".join(
                            one_line(t, 120) for t in user_texts[:5]
                        )
                        msg = (
                            f"(no summary text recorded; compaction replayed "
                            f"{len(user_texts)} prior user turn(s): {preview})"
                        )
                    else:
                        msg = "(compaction boundary; no summary text recorded)"
                items.append({"kind": "compacted", "ts": ts, "text": msg})
                continue

            if rtype != "response_item":
                continue

            ptype = payload.get("type")

            if ptype == "message":
                role = payload.get("role")
                if role not in ("user", "assistant"):
                    continue
                body = "\n\n".join(_texts(payload.get("content"))).strip()
                if not body:
                    continue
                if role == "user" and _is_injected(body):
                    continue
                items.append({"kind": role, "ts": ts, "text": body})
                continue

            if ptype in ("custom_tool_call", "function_call"):
                call_id = payload.get("call_id")
                label, body, raw_for_files = _extract_call(payload, ptype)
                if isinstance(raw_for_files, str):
                    _collect_patch_files(raw_for_files, files_seen)
                if label == "$":
                    _collect_shell_write_files(body, files_seen)
                pending[call_id] = {"label": label, "body": body, "ts": ts}
                continue

            if ptype in ("custom_tool_call_output", "function_call_output"):
                call_id = payload.get("call_id")
                out_text = _output_text(payload.get("output"))
                call = pending.pop(call_id, None)
                if call is None:
                    items.append({
                        "kind": "command", "ts": ts,
                        "label": f"(unmatched call_id {call_id})",
                        "cmd": "", "output": out_text,
                    })
                else:
                    items.append({
                        "kind": "command", "ts": call["ts"],
                        "label": call["label"], "cmd": call["body"],
                        "output": out_text,
                    })
                continue

            # everything else (reasoning, agent_message,
            # inter_agent_communication_metadata, developer messages, ...)
            # is dropped by design.

    # orphan calls with no recorded output before the rollout ended (files
    # were already collected at call-creation time, above)
    for call in pending.values():
        items.append({
            "kind": "command", "ts": call["ts"], "label": call["label"],
            "cmd": call["body"], "output": "[no output recorded before rollout ended]",
        })

    items.sort(key=lambda it: it.get("ts") or "")
    return meta, items, files_seen


# --------------------------------------------------------------------------
# extract — rendering + budget
# --------------------------------------------------------------------------

def _cap_text(text: str, cap: int) -> str:
    if len(text) <= cap:
        return text
    dropped = len(text) - cap
    return text[:cap] + f"\n[... {dropped} more chars truncated]"


def _render_item(item: dict) -> str:
    ts = item.get("ts") or "?"
    kind = item["kind"]
    if kind == "user":
        return f"### USER  [{ts}]\n{item['text']}\n"
    if kind == "assistant":
        return f"### ASSISTANT  [{ts}]\n{item['text']}\n"
    if kind == "compacted":
        return f"### COMPACTION BOUNDARY  [{ts}]\n{item['text']}\n"
    if kind == "command":
        label = item.get("label", "")
        cmd = item.get("cmd", "")
        cmd_line = f"{label} {cmd}".strip() if label != "$" else f"$ {cmd}"
        output = item.get("output", "")
        return f"### COMMAND  [{ts}]\n{cmd_line}\n--- output ---\n{output}\n"
    return ""


def _prepare_items_for_render(items: list) -> list:
    """Apply per-item caps (independent of the overall budget)."""
    prepared = []
    for item in items:
        it = dict(item)
        if it["kind"] == "assistant":
            it["text"] = _cap_text(it["text"], ASSISTANT_CAP)
        elif it["kind"] == "command":
            output = it.get("output", "") or ""
            cap = CMD_OUTPUT_CAP_ERROR if _looks_like_error(output) else CMD_OUTPUT_CAP_NORMAL
            it["output"] = _cap_text(output, cap)
            cmd = it.get("cmd", "")
            if isinstance(cmd, str):
                it["cmd"] = _cap_text(cmd, CMD_TEXT_CAP)
        prepared.append(it)
    return prepared


def _compress_command_output(item: dict) -> dict:
    it = dict(item)
    n = len(item.get("output", "") or "")
    it["output"] = f"[output omitted to fit --max-chars budget; was {n} chars]"
    return it


def _compress_assistant(item: dict) -> dict:
    it = dict(item)
    it["text"] = _cap_text(item["text"], 300)
    return it


def _compress_command_cmd(item: dict) -> dict:
    it = dict(item)
    it["cmd"] = "[command text omitted to fit --max-chars budget]"
    it["output"] = "[output omitted to fit --max-chars budget]"
    return it


def build_header(thread_id: str, meta: dict, title: str, rollout_path: str) -> str:
    lines = [
        f"# Codex thread {thread_id}",
        "",
        f"cwd: {meta.get('cwd') or 'unknown'}",
        f"branch: {meta.get('branch') or 'unknown'}",
        f"first message: {meta.get('first_ts') or 'unknown'}",
        f"last message: {meta.get('last_ts') or 'unknown'}",
        f"title: {title}",
        f"cli_version: {meta.get('cli_version') or 'unknown'}",
        f"rollout: {rollout_path}",
        "",
    ]
    return "\n".join(lines)


def build_compaction_summary(items: list) -> str:
    compactions = [it for it in items if it["kind"] == "compacted"]
    if not compactions:
        return ""
    parts = ["## Compaction summaries", ""]
    for it in compactions:
        parts.append(f"- [{it.get('ts') or '?'}] {it['text']}")
    parts.append("")
    return "\n".join(parts)


def build_files_section(files: set) -> str:
    parts = [
        "## Files this thread appears to have written or edited (heuristic)",
        "",
        "Derived from apply_patch headers and shell redirects/writes seen in",
        "commands. Not verified against disk; the handoff writer must check.",
        "",
    ]
    if not files:
        parts.append("(none detected)")
    else:
        for f in sorted(files):
            parts.append(f"- {f}")
    parts.append("")
    return "\n".join(parts)


def render_transcript(thread_id: str, meta: dict, items: list, files_seen: set,
                       title: str, rollout_path: str, max_chars: int) -> str:
    header = build_header(thread_id, meta, title, rollout_path)
    compaction_summary = build_compaction_summary(items)
    files_section = build_files_section(files_seen)

    prepared = _prepare_items_for_render(items)
    rendered = [_render_item(it) for it in prepared]

    static_len = len(header) + len(compaction_summary) + len(files_section) + len("## Conversation\n\n")
    total = static_len + sum(len(r) for r in rendered)

    if total > max_chars:
        protect_from = max(0, len(prepared) - PROTECT_RECENT_ITEMS)

        # Pass 1: drop command outputs, oldest first.
        for i in range(protect_from):
            if prepared[i]["kind"] != "command":
                continue
            old = len(rendered[i])
            prepared[i] = _compress_command_output(prepared[i])
            rendered[i] = _render_item(prepared[i])
            total -= old - len(rendered[i])
            if total <= max_chars:
                break

        # Pass 2: shrink older assistant messages.
        if total > max_chars:
            for i in range(protect_from):
                if prepared[i]["kind"] != "assistant":
                    continue
                old = len(rendered[i])
                prepared[i] = _compress_assistant(prepared[i])
                rendered[i] = _render_item(prepared[i])
                total -= old - len(rendered[i])
                if total <= max_chars:
                    break

        # Pass 3: drop command text too (rare — huge heredocs).
        if total > max_chars:
            for i in range(protect_from):
                if prepared[i]["kind"] != "command":
                    continue
                old = len(rendered[i])
                prepared[i] = _compress_command_cmd(prepared[i])
                rendered[i] = _render_item(prepared[i])
                total -= old - len(rendered[i])
                if total <= max_chars:
                    break

    doc = (
        header
        + compaction_summary
        + "## Conversation\n\n"
        + "\n".join(rendered)
        + "\n"
        + files_section
    )

    if len(doc) > max_chars:
        # Last resort: user messages and compaction summaries alone exceed
        # the budget. Hard-truncate the tail rather than drop required
        # content silently; a warning marks that this happened.
        doc = doc[:max_chars] + (
            "\n\n[... transcript truncated to fit --max-chars budget; "
            "not all content is shown ...]\n"
        )

    return doc


# --------------------------------------------------------------------------
# extract — thread resolution
# --------------------------------------------------------------------------

def resolve_rollout(target: str):
    """Returns (thread_id, rollout_path, db_row_or_None)."""
    looks_like_path = (os.sep in target or target.endswith(".jsonl"))
    if looks_like_path and os.path.isfile(target):
        return None, target, None

    con = connect_ro(db_path())
    try:
        row = fetch_thread_by_id(con, target)
        if row is not None:
            return row["id"], row["rollout_path"], row
        candidates = fetch_threads_by_prefix(con, target)
    finally:
        con.close()

    if not candidates:
        raise SystemExit(f"codex_threads: no Codex thread found matching '{target}'")
    if len(candidates) > 1:
        lines = [f"codex_threads: ambiguous thread id/prefix '{target}'; candidates:"]
        for c in candidates[:20]:
            lines.append(
                f"  {c['id']}  cwd={c.get('cwd')}  title={one_line(display_title(c), 60)}"
            )
        raise SystemExit("\n".join(lines))
    row = candidates[0]
    return row["id"], row["rollout_path"], row


def cmd_extract(args) -> int:
    thread_id, rollout_path, row = resolve_rollout(args.target)
    if not rollout_path or not os.path.isfile(rollout_path):
        raise SystemExit(f"codex_threads: rollout file not found: {rollout_path}")

    meta, items, files_seen = parse_rollout(rollout_path)
    thread_id = thread_id or meta.get("thread_id") or "unknown"
    title = display_title(row) if row else (meta.get("thread_id") or "unknown")
    # Some Codex CLI versions don't record git info in session_meta at all;
    # the thread index db sometimes has it even then.
    if not meta.get("branch") and row and row.get("git_branch"):
        meta["branch"] = row["git_branch"]

    doc = render_transcript(
        thread_id, meta, items, files_seen, title, rollout_path, args.max_chars
    )

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(doc)
        print(f"codex_threads: wrote {len(doc)} chars to {args.out}")
    else:
        sys.stdout.write(doc)
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="codex_threads.py", description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)

    lst = sub.add_parser("list", help="list recent Codex threads for a repo")
    lst.add_argument("--cwd", default=None, help="repo dir (default: current directory)")
    lst.add_argument("--limit", type=int, default=20)
    lst.add_argument("--all-sources", action="store_true",
                      help="include guardian/subagent threads")
    lst.add_argument("--include-archived", action="store_true")
    lst.add_argument("--json", action="store_true")
    lst.set_defaults(func=cmd_list)

    ext = sub.add_parser("extract", help="condense a rollout into a handoff-ready transcript")
    ext.add_argument("target", help="thread id, unique id prefix, or a rollout .jsonl path")
    ext.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    ext.add_argument("--out", default=None, help="write to this file instead of stdout")
    ext.set_defaults(func=cmd_extract)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
