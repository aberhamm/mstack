#!/usr/bin/env python3
"""Tests for codex_threads.py. Stdlib unittest, no external deps.

Uses synthetic rollout fixtures (written to a temp dir) and a temp sqlite
db built with the same schema shape as ~/.codex/state_5.sqlite, so no real
~/.codex data is ever touched.

Run directly: python3 codex_threads_test.py
Or via the smoke wrapper: bash codex-threads-smoke.sh
"""
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(HERE, "codex_threads.py")

spec = importlib.util.spec_from_file_location("codex_threads", MODULE_PATH)
codex_threads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codex_threads)  # type: ignore[union-attr]


THREAD_COLUMNS = codex_threads.THREAD_COLUMNS


_INTEGER_COLUMNS = {"archived", "updated_at_ms", "updated_at", "tokens_used"}


def make_db(path, rows):
    # Mirror ~/.codex/state_5.sqlite's real column affinity (INTEGER for the
    # boolean/numeric columns) rather than declaring everything TEXT — a
    # TEXT-typed "archived" column round-trips 0 as the string "0", which is
    # truthy in Python and would hide a real bug in the code under test.
    con = sqlite3.connect(path)
    cols_sql = ", ".join(
        f"{c} {'INTEGER' if c in _INTEGER_COLUMNS else 'TEXT'}" for c in THREAD_COLUMNS
    )
    con.execute(f"CREATE TABLE threads ({cols_sql})")
    placeholders = ", ".join("?" for _ in THREAD_COLUMNS)
    for row in rows:
        values = [row.get(c) for c in THREAD_COLUMNS]
        con.execute(f"INSERT INTO threads VALUES ({placeholders})", values)
    con.commit()
    con.close()


def default_row(**overrides):
    row = {
        "id": "01a0aaaa-0000-0000-0000-000000000001",
        "rollout_path": "/tmp/does-not-matter.jsonl",
        "cwd": "/Users/test/dev/project",
        "title": "a title",
        "name": None,
        "first_user_message": "hello",
        "source": "vscode",
        "archived": 0,
        "updated_at_ms": 1000,
        "updated_at": 1,
        "tokens_used": 100,
        "git_branch": "main",
    }
    row.update(overrides)
    return row


def jl(rec) -> str:
    return json.dumps(rec) + "\n"


class ListCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = os.path.join(self.tmp.name, "state.sqlite")
        self.env_patch = None

    def _run_list(self, **kwargs):
        os.environ["MSTACK_CODEX_STATE_DB"] = self.db_path
        parser = codex_threads.build_parser()
        argv = ["list"]
        if "cwd" in kwargs:
            argv += ["--cwd", kwargs["cwd"]]
        if kwargs.get("all_sources"):
            argv.append("--all-sources")
        if kwargs.get("include_archived"):
            argv.append("--include-archived")
        if kwargs.get("as_json"):
            argv.append("--json")
        if "limit" in kwargs:
            argv += ["--limit", str(kwargs["limit"])]
        args = parser.parse_args(argv)
        buf = io.StringIO()
        with redirect_stdout(buf):
            codex_threads.cmd_list(args)
        return buf.getvalue()

    def test_guardian_and_subagent_threads_excluded_by_default(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="real thread", source="vscode"),
            default_row(id="01a0aaaa-0002", name="guardian review",
                        source='{"subagent":{"other":"guardian"}}'),
            default_row(id="01a0aaaa-0003", name="spawned subagent",
                        source='{"subagent":{"thread_spawn":{"parent_thread_id":"x"}}}'),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project")
        self.assertIn("real thread", out)
        self.assertNotIn("guardian review", out)
        self.assertNotIn("spawned subagent", out)

    def test_all_sources_includes_guardian(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="real thread", source="vscode"),
            default_row(id="01a0aaaa-0002", name="guardian review",
                        source='{"subagent":{"other":"guardian"}}'),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project", all_sources=True)
        self.assertIn("guardian review", out)

    def test_cwd_filters_exact_and_subdirectory(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="exact", cwd="/Users/test/dev/project"),
            default_row(id="01a0aaaa-0002", name="subdir", cwd="/Users/test/dev/project/sub"),
            default_row(id="01a0aaaa-0003", name="other repo", cwd="/Users/test/dev/other"),
            default_row(id="01a0aaaa-0004", name="prefix collision",
                        cwd="/Users/test/dev/project-two"),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project")
        self.assertIn("exact", out)
        self.assertIn("subdir", out)
        self.assertNotIn("other repo", out)
        self.assertNotIn("prefix collision", out)

    def test_archived_excluded_by_default_included_with_flag(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="live", archived=0),
            default_row(id="01a0aaaa-0002", name="archived one", archived=1),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project")
        self.assertIn("live", out)
        self.assertNotIn("archived one", out)
        out2 = self._run_list(cwd="/Users/test/dev/project", include_archived=True)
        self.assertIn("archived one", out2)

    def test_title_precedence_name_then_title_then_first_user_message(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="short name", title="long raw title"),
            default_row(id="01a0aaaa-0002", name=None, title="a real title",
                        first_user_message="fallback text"),
            default_row(id="01a0aaaa-0003", name=None, title=None,
                        first_user_message="only fum"),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project", as_json=True)
        data = json.loads(out)
        by_id = {d["id"]: d["title"] for d in data}
        self.assertEqual(by_id["01a0aaaa-0001"], "short name")
        self.assertEqual(by_id["01a0aaaa-0002"], "a real title")
        self.assertEqual(by_id["01a0aaaa-0003"], "only fum")

    def test_sorted_newest_first_and_limit(self):
        rows = [
            default_row(id="01a0aaaa-0001", name="oldest", updated_at_ms=100),
            default_row(id="01a0aaaa-0002", name="newest", updated_at_ms=300),
            default_row(id="01a0aaaa-0003", name="middle", updated_at_ms=200),
        ]
        make_db(self.db_path, rows)
        out = self._run_list(cwd="/Users/test/dev/project", as_json=True)
        data = json.loads(out)
        self.assertEqual([d["name"] for d in data], ["newest", "middle", "oldest"])

        out2 = self._run_list(cwd="/Users/test/dev/project", as_json=True, limit=1)
        data2 = json.loads(out2)
        self.assertEqual(len(data2), 1)
        self.assertEqual(data2[0]["name"], "newest")


class ExtractResolutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = os.path.join(self.tmp.name, "state.sqlite")
        os.environ["MSTACK_CODEX_STATE_DB"] = self.db_path

    def test_exact_id_resolves(self):
        rollout = os.path.join(self.tmp.name, "r1.jsonl")
        open(rollout, "w").close()
        rows = [default_row(id="01a0bbbb-full-id", rollout_path=rollout)]
        make_db(self.db_path, rows)
        tid, path, row = codex_threads.resolve_rollout("01a0bbbb-full-id")
        self.assertEqual(tid, "01a0bbbb-full-id")
        self.assertEqual(path, rollout)

    def test_unique_prefix_resolves(self):
        rollout = os.path.join(self.tmp.name, "r1.jsonl")
        open(rollout, "w").close()
        rows = [
            default_row(id="01a0cccc-1111", rollout_path=rollout),
            default_row(id="01a0dddd-2222", rollout_path=rollout),
        ]
        make_db(self.db_path, rows)
        tid, path, row = codex_threads.resolve_rollout("01a0cccc")
        self.assertEqual(tid, "01a0cccc-1111")

    def test_ambiguous_prefix_lists_candidates_and_exits(self):
        rows = [
            default_row(id="01a0eeee-1111", name="first candidate"),
            default_row(id="01a0eeee-2222", name="second candidate"),
        ]
        make_db(self.db_path, rows)
        with self.assertRaises(SystemExit) as ctx:
            codex_threads.resolve_rollout("01a0eeee")
        msg = str(ctx.exception)
        self.assertIn("ambiguous", msg.lower())
        self.assertIn("first candidate", msg)
        self.assertIn("second candidate", msg)

    def test_no_match_raises(self):
        make_db(self.db_path, [default_row(id="01a0ffff-1111")])
        with self.assertRaises(SystemExit) as ctx:
            codex_threads.resolve_rollout("nonexistent")
        self.assertIn("no Codex thread found", str(ctx.exception))

    def test_direct_rollout_path_bypasses_db(self):
        rollout = os.path.join(self.tmp.name, "direct.jsonl")
        open(rollout, "w").close()
        # No rows in the db at all — must still resolve via the path.
        make_db(self.db_path, [])
        tid, path, row = codex_threads.resolve_rollout(rollout)
        self.assertIsNone(tid)
        self.assertEqual(path, rollout)
        self.assertIsNone(row)


class ParseRolloutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _write(self, records):
        path = os.path.join(self.tmp.name, "rollout.jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            for rec in records:
                fh.write(jl(rec))
        return path

    def test_session_meta_captures_cwd_and_branch(self):
        path = self._write([
            {"timestamp": "t0", "type": "session_meta",
             "payload": {"id": "tid-1", "cwd": "/repo", "git": {"branch": "main"},
                         "cli_version": "1.2.3"}},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertEqual(meta["cwd"], "/repo")
        self.assertEqual(meta["branch"], "main")
        self.assertEqual(meta["thread_id"], "tid-1")
        self.assertEqual(meta["cli_version"], "1.2.3")

    def test_injected_context_is_skipped(self):
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": [{"type": "input_text",
                             "text": "<environment_context>\nsome harness junk\n</environment_context>"}],
            }},
            {"timestamp": "t2", "type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": [{"type": "input_text", "text": "real user question"}],
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        user_items = [it for it in items if it["kind"] == "user"]
        self.assertEqual(len(user_items), 1)
        self.assertEqual(user_items[0]["text"], "real user question")

    def test_developer_role_is_dropped(self):
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "message", "role": "developer",
                "content": [{"type": "input_text", "text": "system stuff"}],
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertEqual(items, [])

    def test_custom_tool_call_pairs_with_output_by_call_id(self):
        # Real Codex rollouts mix both a quoted-key ({"cmd":"...) and an
        # unquoted JS-shorthand ({cmd:"...) form for the same "exec" tool
        # across calls in a single session; both must extract cleanly.
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_1", "name": "exec",
                "input": 'const r = await tools.exec_command({"cmd":"echo hi","workdir":"/repo"}); text(r.output);\n',
            }},
            {"timestamp": "t2", "type": "response_item", "payload": {
                "type": "custom_tool_call_output", "call_id": "call_1",
                "output": [{"type": "input_text", "text": "hi\n"}],
            }},
            {"timestamp": "t3", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_2", "name": "exec",
                "input": 'const r = await tools.exec_command({cmd:"echo bye"}); text(r.output);\n',
            }},
            {"timestamp": "t4", "type": "response_item", "payload": {
                "type": "custom_tool_call_output", "call_id": "call_2",
                "output": "bye\n",
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        commands = [it for it in items if it["kind"] == "command"]
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0]["cmd"], "echo hi")
        self.assertEqual(commands[0]["output"], "hi\n")
        self.assertEqual(commands[0]["ts"], "t1")  # timestamp of the call, not the output
        self.assertEqual(commands[1]["cmd"], "echo bye")
        self.assertEqual(commands[1]["output"], "bye\n")

    def test_function_call_output_pairs_by_call_id_ignoring_order(self):
        # Two calls interleaved with their outputs out of naive adjacency.
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "function_call", "call_id": "call_a", "name": "shell",
                "arguments": '{"cmd": "one"}',
            }},
            {"timestamp": "t2", "type": "response_item", "payload": {
                "type": "function_call", "call_id": "call_b", "name": "shell",
                "arguments": '{"cmd": "two"}',
            }},
            {"timestamp": "t3", "type": "response_item", "payload": {
                "type": "function_call_output", "call_id": "call_b", "output": "two-out",
            }},
            {"timestamp": "t4", "type": "response_item", "payload": {
                "type": "function_call_output", "call_id": "call_a", "output": "one-out",
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        commands = [it for it in items if it["kind"] == "command"]
        by_cmd = {c["cmd"]: c["output"] for c in commands}
        self.assertEqual(by_cmd["one"], "one-out")
        self.assertEqual(by_cmd["two"], "two-out")

    def test_orphan_call_with_no_output_is_reported(self):
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_x", "name": "exec",
                "input": 'const r = await tools.exec_command({"cmd":"stuck"}); text(r.output);\n',
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        commands = [it for it in items if it["kind"] == "command"]
        self.assertEqual(len(commands), 1)
        self.assertIn("no output recorded", commands[0]["output"])

    def test_compacted_record_kept_with_message(self):
        path = self._write([
            {"timestamp": "t1", "type": "compacted",
             "payload": {"message": "earlier work summarized here"}},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["kind"], "compacted")
        self.assertIn("earlier work summarized here", items[0]["text"])

    def test_compacted_record_with_empty_message_falls_back_to_replacement_history(self):
        path = self._write([
            {"timestamp": "t1", "type": "compacted", "payload": {
                "message": "",
                "replacement_history": [
                    {"role": "user", "content": [{"type": "input_text", "text": "do the thing"}]},
                ],
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertEqual(len(items), 1)
        self.assertIn("do the thing", items[0]["text"])

    def test_reasoning_and_token_records_are_dropped(self):
        path = self._write([
            {"timestamp": "t1", "type": "response_item",
             "payload": {"type": "reasoning", "encrypted_content": "gAAAA..."}},
            {"timestamp": "t2", "type": "token_count", "payload": {"tokens": 5}},
            {"timestamp": "t3", "type": "turn_context", "payload": {}},
            {"timestamp": "t4", "type": "event_msg", "payload": {"type": "user_message"}},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertEqual(items, [])

    def test_apply_patch_and_redirect_detected_as_files(self):
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_1", "name": "exec",
                "input": 'const r = await tools.exec_command({"cmd":"echo hi > out/notes.md"}); text(r.output);\n',
            }},
            {"timestamp": "t2", "type": "response_item", "payload": {
                "type": "custom_tool_call_output", "call_id": "call_1",
                "output": "ok",
            }},
            {"timestamp": "t3", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_2", "name": "apply_patch",
                "input": "*** Begin Patch\n*** Update File: src/app.py\n*** End Patch",
            }},
            {"timestamp": "t4", "type": "response_item", "payload": {
                "type": "custom_tool_call_output", "call_id": "call_2", "output": "applied",
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertIn("out/notes.md", files)
        self.assertIn("src/app.py", files)

    def test_apply_patch_built_as_js_string_still_detected(self):
        # Real Codex data: an apply_patch call is sometimes not its own
        # tool call at all but a "const patch = ..." JS string passed
        # through the same "exec" custom_tool_call — the exec_command cmd
        # regex will not match this input, but the patch headers inside it
        # must still be picked up for the files-touched heuristic.
        raw = (
            'const patch = "*** Begin Patch\\n*** Add File: notes/new.md\\n'
            '+hello\\n*** End Patch"; await tools.apply_patch({patch});\n'
        )
        path = self._write([
            {"timestamp": "t1", "type": "response_item", "payload": {
                "type": "custom_tool_call", "call_id": "call_1", "name": "exec",
                "input": raw,
            }},
            {"timestamp": "t2", "type": "response_item", "payload": {
                "type": "custom_tool_call_output", "call_id": "call_1", "output": "done",
            }},
        ])
        meta, items, files = codex_threads.parse_rollout(path)
        self.assertIn("notes/new.md", files)
        commands = [it for it in items if it["kind"] == "command"]
        self.assertEqual(len(commands), 1)
        self.assertIn("apply_patch", commands[0]["label"])


class BudgetTruncationTests(unittest.TestCase):
    def _make_items(self, n_user, n_commands, big_output_len):
        items = []
        for i in range(n_user):
            items.append({"kind": "user", "ts": f"u{i}", "text": f"user message {i}"})
        for i in range(n_commands):
            items.append({
                "kind": "command", "ts": f"c{i}",
                "label": "$", "cmd": f"cmd {i}",
                "output": "X" * big_output_len,
            })
        return items

    def test_small_transcript_is_not_truncated(self):
        items = self._make_items(2, 2, 50)
        doc = codex_threads.render_transcript(
            "tid", {"cwd": "/repo"}, items, set(), "title", "/rollout.jsonl",
            max_chars=1_000_000,
        )
        self.assertIn("user message 0", doc)
        self.assertIn("X" * 50, doc)
        self.assertNotIn("omitted to fit", doc)

    def test_over_budget_compresses_older_command_output_first(self):
        items = self._make_items(2, 30, 500)
        doc = codex_threads.render_transcript(
            "tid", {"cwd": "/repo"}, items, set(), "title", "/rollout.jsonl",
            max_chars=15_000,
        )
        # User messages must always survive in full.
        self.assertIn("user message 0", doc)
        self.assertIn("user message 1", doc)
        # Some older command output must have been compressed.
        self.assertIn("omitted to fit", doc)
        self.assertLessEqual(len(doc), 15_000 + 500)  # small slack for the warning banner

    def test_most_recent_commands_are_protected(self):
        items = self._make_items(1, codex_threads.PROTECT_RECENT_ITEMS + 5, 300)
        doc = codex_threads.render_transcript(
            "tid", {"cwd": "/repo"}, items, set(), "title", "/rollout.jsonl",
            max_chars=8_000,
        )
        last_cmd_idx = codex_threads.PROTECT_RECENT_ITEMS + 4
        self.assertIn(f"cmd {last_cmd_idx}", doc)
        pos = doc.find(f"cmd {last_cmd_idx}")
        # The most recent command's output should still be the full 300 X's,
        # not a compression stub, since it is inside the protected window.
        self.assertIn("X" * 300, doc[pos:pos + 1000])

    def test_extreme_budget_falls_back_to_hard_truncate_with_warning(self):
        items = self._make_items(200, 5, 100)
        doc = codex_threads.render_transcript(
            "tid", {"cwd": "/repo"}, items, set(), "title", "/rollout.jsonl",
            max_chars=500,
        )
        self.assertIn("transcript truncated to fit --max-chars budget", doc)
        self.assertLessEqual(len(doc), 500 + 200)


class HelperTests(unittest.TestCase):
    def test_is_real_source(self):
        self.assertTrue(codex_threads.is_real_source("vscode"))
        self.assertTrue(codex_threads.is_real_source("cli"))
        self.assertTrue(codex_threads.is_real_source("exec"))
        self.assertFalse(codex_threads.is_real_source('{"subagent":{"other":"guardian"}}'))
        self.assertFalse(codex_threads.is_real_source(None))

    def test_cwd_matches_exact_and_subdir_not_prefix_collision(self):
        self.assertTrue(codex_threads.cwd_matches("/a/b", "/a/b"))
        self.assertTrue(codex_threads.cwd_matches("/a/b/c", "/a/b"))
        self.assertFalse(codex_threads.cwd_matches("/a/b-two", "/a/b"))
        self.assertFalse(codex_threads.cwd_matches(None, "/a/b"))

    def test_display_title_precedence(self):
        self.assertEqual(
            codex_threads.display_title({"name": "n", "title": "t", "first_user_message": "f"}),
            "n",
        )
        self.assertEqual(
            codex_threads.display_title({"name": None, "title": "t", "first_user_message": "f"}),
            "t",
        )
        self.assertEqual(
            codex_threads.display_title({"name": None, "title": None, "first_user_message": "f"}),
            "f",
        )
        self.assertEqual(
            codex_threads.display_title({"name": "", "title": "", "first_user_message": ""}),
            "(untitled)",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
