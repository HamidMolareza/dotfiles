from __future__ import annotations

import json
import os
import runpy
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from pathlib import Path
from typing import Any


SCRIPT = Path(__file__).resolve().parents[1] / "codex-session-usage"


class CodexSessionUsageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="codex-session-usage-test-"))
        self.addCleanup(shutil.rmtree, self.temp_dir)
        self.codex_home = self.temp_dir / ".codex"
        self.codex_home.mkdir()
        self.now = datetime.now(timezone.utc)

    def create_database(
        self,
        *,
        include_name: bool = False,
        include_created_at: bool = True,
    ) -> sqlite3.Connection:
        database = self.codex_home / "state_5.sqlite"
        connection = sqlite3.connect(database)
        name_column = ", name TEXT" if include_name else ""
        created_at_column = "created_at_ms INTEGER NOT NULL," if include_created_at else ""
        connection.executescript(
            f"""
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    rollout_path TEXT NOT NULL,
    source TEXT NOT NULL,
    cwd TEXT NOT NULL,
    title TEXT NOT NULL,
    tokens_used INTEGER NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0,
    first_user_message TEXT NOT NULL DEFAULT '',
    updated_at_ms INTEGER NOT NULL,
    {created_at_column}
    preview TEXT NOT NULL DEFAULT '',
    recency_at_ms INTEGER NOT NULL
    {name_column}
);
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id TEXT NOT NULL PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'open'
);
"""
        )
        return connection

    def add_thread(
        self,
        connection: sqlite3.Connection,
        thread_id: str,
        *,
        source: str = "cli",
        title: str | None = None,
        name: str | None = None,
        tokens_used: int = 0,
        recency: int = 0,
        created_at: datetime | None = None,
        updated_at: datetime | None = None,
        archived: bool = False,
        events: list[dict[str, Any] | str] | None = None,
    ) -> Path:
        rollout = self.codex_home / "sessions" / f"rollout-{thread_id}.jsonl"
        rollout.parent.mkdir(parents=True, exist_ok=True)
        with rollout.open("w", encoding="utf-8") as handle:
            for event in events or []:
                if isinstance(event, str):
                    handle.write(event + "\n")
                else:
                    handle.write(json.dumps(event) + "\n")

        thread_columns = {
            str(row[1]) for row in connection.execute("PRAGMA table_info(threads)")
        }
        updated_at_value = updated_at or self.now
        columns = [
            "id",
            "rollout_path",
            "source",
            "cwd",
            "title",
            "tokens_used",
            "archived",
            "first_user_message",
            "updated_at_ms",
            "preview",
            "recency_at_ms",
        ]
        values: list[Any] = [
            thread_id,
            str(rollout),
            source,
            "/tmp/project",
            title or thread_id,
            tokens_used,
            int(archived),
            title or thread_id,
            int(updated_at_value.timestamp() * 1000),
            title or thread_id,
            recency,
        ]
        if "created_at_ms" in thread_columns:
            columns.append("created_at_ms")
            values.append(int((created_at or updated_at_value).timestamp() * 1000))
        if name is not None:
            columns.append("name")
            values.append(name)
        placeholders = ", ".join("?" for _ in values)
        connection.execute(
            f"INSERT INTO threads ({', '.join(columns)}) VALUES ({placeholders})",
            values,
        )
        return rollout

    @staticmethod
    def token_event(
        timestamp: datetime,
        *,
        last: int | None,
        cumulative: int,
        input_tokens: int | None = None,
        cached_input_tokens: int | None = None,
        output_tokens: int | None = None,
        reasoning_output_tokens: int | None = None,
    ) -> dict[str, Any]:
        cumulative_usage: dict[str, int] = {"total_tokens": cumulative}
        optional_components = {
            "input_tokens": input_tokens,
            "cached_input_tokens": cached_input_tokens,
            "output_tokens": output_tokens,
            "reasoning_output_tokens": reasoning_output_tokens,
        }
        cumulative_usage.update(
            {
                name: value
                for name, value in optional_components.items()
                if value is not None
            }
        )
        info: dict[str, Any] = {
            "total_token_usage": cumulative_usage,
        }
        if last is not None:
            info["last_token_usage"] = {"total_tokens": last}
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {"type": "token_count", "info": info},
        }

    @staticmethod
    def user_event(timestamp: datetime, message: str) -> dict[str, Any]:
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {"type": "user_message", "message": message},
        }

    @staticmethod
    def agent_event(timestamp: datetime, message: str) -> dict[str, Any]:
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": message},
        }

    @staticmethod
    def tool_event(timestamp: datetime, name: str, arguments: str) -> dict[str, Any]:
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "response_item",
            "payload": {
                "type": "custom_tool_call",
                "name": name,
                "arguments": arguments,
            },
        }

    def run_script(
        self,
        *arguments: str,
        current_thread_id: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if current_thread_id is None:
            environment.pop("CODEX_THREAD_ID", None)
        else:
            environment["CODEX_THREAD_ID"] = current_thread_id
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments, "--codex-home", str(self.codex_home)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def test_selects_recent_roots_then_sorts_and_aggregates_descendants(self) -> None:
        connection = self.create_database()
        recent = self.now - timedelta(hours=1)
        old = self.now - timedelta(days=8)

        self.add_thread(
            connection,
            "root-alpha",
            title="Alpha\nroot session",
            tokens_used=100,
            recency=300,
            created_at=self.now - timedelta(hours=2, minutes=5),
            updated_at=self.now,
            events=[self.token_event(recent, last=100, cumulative=100)],
        )
        self.add_thread(
            connection,
            "alpha-child",
            source='{"subagent":{"thread_spawn":{"parent_thread_id":"root-alpha"}}}',
            tokens_used=200,
            recency=290,
            events=[self.token_event(recent, last=200, cumulative=200)],
        )
        self.add_thread(
            connection,
            "alpha-grandchild",
            source='{"subagent":{"thread_spawn":{"parent_thread_id":"alpha-child"}}}',
            tokens_used=300,
            recency=280,
            events=[self.token_event(recent, last=300, cumulative=300)],
        )
        connection.executemany(
            "INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id) VALUES (?, ?)",
            (("root-alpha", "alpha-child"), ("alpha-child", "alpha-grandchild")),
        )

        self.add_thread(
            connection,
            "root-beta",
            title="Beta root",
            tokens_used=700,
            recency=200,
            events=[self.token_event(recent, last=700, cumulative=700)],
        )
        self.add_thread(
            connection,
            "root-old-huge",
            title="Old huge root",
            tokens_used=9_999,
            recency=100,
            events=[self.token_event(old, last=9_999, cumulative=9_999)],
        )
        self.add_thread(
            connection,
            "exec-denominator",
            source="exec",
            tokens_used=400,
            recency=90,
            events=[self.token_event(recent, last=400, cumulative=400)],
        )
        self.add_thread(
            connection,
            "archived-denominator",
            tokens_used=100,
            recency=80,
            archived=True,
            events=[self.token_event(recent, last=100, cumulative=100)],
        )
        connection.commit()
        connection.close()

        result = self.run_script("2", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)

        self.assertEqual(payload["window"]["total_tokens"], 1_800)
        self.assertEqual([item["thread_id"] for item in payload["sessions"]], ["root-beta", "root-alpha"])
        alpha = payload["sessions"][1]
        self.assertEqual(alpha["main_tokens"], 100)
        self.assertEqual(alpha["subagent_tokens"], 500)
        self.assertEqual(alpha["total_tokens"], 600)
        self.assertEqual(alpha["subagent_count"], 2)
        self.assertEqual(alpha["window_tokens"], 600)
        self.assertAlmostEqual(alpha["window_share_percent"], 100 / 3)
        self.assertEqual(alpha["display_title"], "Alpha root session")
        self.assertEqual(alpha["duration_seconds"], 7_500)

    def test_current_session_is_included_by_default_and_can_be_excluded(self) -> None:
        connection = self.create_database()
        recent = self.now - timedelta(minutes=5)
        self.add_thread(
            connection,
            "current-thread",
            tokens_used=10,
            recency=200,
            events=[self.token_event(recent, last=10, cumulative=10)],
        )
        self.add_thread(
            connection,
            "previous-thread",
            tokens_used=20,
            recency=100,
            events=[self.token_event(recent, last=20, cumulative=20)],
        )
        connection.commit()
        connection.close()

        included = self.run_script("1", "--json", current_thread_id="current-thread")
        self.assertEqual(included.returncode, 0, included.stderr)
        self.assertEqual(json.loads(included.stdout)["sessions"][0]["thread_id"], "current-thread")

        excluded = self.run_script(
            "1",
            "--json",
            "--exclude-current",
            current_thread_id="current-thread",
        )
        self.assertEqual(excluded.returncode, 0, excluded.stderr)
        self.assertEqual(json.loads(excluded.stdout)["sessions"][0]["thread_id"], "previous-thread")

    def test_cumulative_only_events_use_delta_and_ignore_outside_window(self) -> None:
        connection = self.create_database()
        outside = self.now - timedelta(days=8)
        inside = self.now - timedelta(hours=1)
        future = self.now + timedelta(days=1)
        self.add_thread(
            connection,
            "cumulative-root",
            tokens_used=200,
            recency=100,
            events=[
                self.token_event(outside, last=None, cumulative=100),
                "{malformed",
                self.token_event(inside, last=None, cumulative=160),
                self.token_event(inside, last=60, cumulative=160),
                {
                    "timestamp": inside.isoformat().replace("+00:00", "Z"),
                    "type": "event_msg",
                    "payload": {
                        "type": "token_count",
                        "info": {"last_token_usage": {"total_tokens": 5}},
                    },
                },
                self.token_event(inside + timedelta(minutes=1), last=5, cumulative=165),
                self.token_event(future, last=None, cumulative=200),
            ],
        )
        connection.commit()
        connection.close()

        result = self.run_script("1", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["window"]["total_tokens"], 65)
        self.assertEqual(payload["sessions"][0]["window_tokens"], 65)
        self.assertEqual(payload["sessions"][0]["window_share_percent"], 100.0)
        self.assertEqual(payload["scan"]["last_usage_fallback_events"], 1)
        self.assertEqual(payload["scan"]["malformed_lines"], 1)

    def test_prefers_optional_saved_name_and_normalizes_it(self) -> None:
        connection = self.create_database(include_name=True)
        self.add_thread(
            connection,
            "named-root",
            title="Fallback title",
            name="  Saved\nCodex   name  ",
            tokens_used=25,
            recency=100,
            events=[self.token_event(self.now - timedelta(minutes=1), last=25, cumulative=25)],
        )
        connection.commit()
        connection.close()

        result = self.run_script("1", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        session = json.loads(result.stdout)["sessions"][0]
        self.assertEqual(session["title"], "Saved Codex name")
        self.assertEqual(session["display_title"], "Saved Codex name")

    def test_text_report_uses_compact_columns_and_relative_age(self) -> None:
        connection = self.create_database()
        active_at = self.now - timedelta(days=1, hours=2)
        root_tokens = 25_989_275
        subagent_tokens = 154_359_118
        self.add_thread(
            connection,
            "compact-root",
            title="Compact report",
            tokens_used=root_tokens,
            recency=int(active_at.timestamp() * 1000),
            created_at=active_at - timedelta(hours=4, minutes=12),
            updated_at=active_at,
            events=[self.token_event(active_at, last=root_tokens, cumulative=root_tokens)],
        )
        self.add_thread(
            connection,
            "compact-child",
            source='{"subagent":{"thread_spawn":{"parent_thread_id":"compact-root"}}}',
            tokens_used=subagent_tokens,
            recency=int(active_at.timestamp() * 1000) - 1,
            events=[
                self.token_event(
                    active_at,
                    last=subagent_tokens,
                    cumulative=subagent_tokens,
                )
            ],
        )
        connection.execute(
            "INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id) VALUES (?, ?)",
            ("compact-root", "compact-child"),
        )
        connection.commit()
        connection.close()

        result = self.run_script("1")
        self.assertEqual(result.returncode, 0, result.stderr)
        header = next(line for line in result.stdout.splitlines() if line.startswith("session"))
        self.assertEqual(
            " ".join(header.split()),
            "session total (subagents) agents 7d share duration active title",
        )
        self.assertNotIn(" main ", f" {header} ")
        self.assertNotIn(" rank ", f" {header} ")
        self.assertNotIn("7d tokens", header)
        self.assertIn("compact-", result.stdout)
        self.assertIn("180,348,393 (154,359,118)", result.stdout)
        self.assertIn("100.00%", result.stdout)
        self.assertIn("4h 12m", result.stdout)
        self.assertIn("1d 2h ago", result.stdout)
        self.assertIn("Compact report", result.stdout)

    def test_list_duration_is_unknown_without_created_at(self) -> None:
        connection = self.create_database(include_created_at=False)
        self.add_thread(
            connection,
            "legacy-root",
            tokens_used=25,
            recency=int(self.now.timestamp() * 1000),
            events=[self.token_event(self.now, last=25, cumulative=25)],
        )
        connection.commit()
        connection.close()

        json_result = self.run_script("1", "--json")
        self.assertEqual(json_result.returncode, 0, json_result.stderr)
        self.assertIsNone(json.loads(json_result.stdout)["sessions"][0]["duration_seconds"])

        text_result = self.run_script("1")
        self.assertEqual(text_result.returncode, 0, text_result.stderr)
        row = next(line for line in text_result.stdout.splitlines() if line.startswith("legacy-r"))
        self.assertIn("  -  ", row)

    def test_list_duration_clamps_negative_values_to_zero(self) -> None:
        connection = self.create_database()
        self.add_thread(
            connection,
            "negative-duration",
            tokens_used=25,
            recency=int(self.now.timestamp() * 1000),
            created_at=self.now,
            updated_at=self.now - timedelta(minutes=1),
            events=[self.token_event(self.now, last=25, cumulative=25)],
        )
        connection.commit()
        connection.close()

        result = self.run_script("1", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["sessions"][0]["duration_seconds"], 0)

    def test_relative_age_uses_at_most_two_units(self) -> None:
        format_relative_age = runpy.run_path(str(SCRIPT))["format_relative_age"]
        reference = datetime(2026, 7, 21, 12, 0, tzinfo=timezone.utc)

        self.assertEqual(format_relative_age(reference, reference), "now")
        self.assertEqual(format_relative_age(reference - timedelta(seconds=42), reference), "42s ago")
        self.assertEqual(
            format_relative_age(reference - timedelta(minutes=18, seconds=42), reference),
            "18m ago",
        )
        self.assertEqual(
            format_relative_age(reference - timedelta(hours=4, minutes=12, seconds=42), reference),
            "4h 12m ago",
        )
        self.assertEqual(
            format_relative_age(reference - timedelta(days=1, hours=2, minutes=42), reference),
            "1d 2h ago",
        )

    def test_session_detail_attributes_tokens_to_user_tasks_and_spawned_agents(self) -> None:
        connection = self.create_database()
        start = self.now - timedelta(hours=2)
        first_task = "Design and implement the stability dashboard"
        second_task = "Hide disabled proxies from the tray menu"
        root_id = "aaaaaaaa-0000-0000-0000-000000000001"
        first_child_id = "bbbbbbbb-0000-0000-0000-000000000001"
        second_child_id = "cccccccc-0000-0000-0000-000000000001"

        self.add_thread(
            connection,
            root_id,
            title="Detailed task attribution",
            tokens_used=400,
            recency=int(start.timestamp() * 1000),
            created_at=start,
            events=[
                self.user_event(start, "# AGENTS.md instructions that must stay private"),
                self.user_event(start + timedelta(minutes=1), first_task),
                self.token_event(
                    start + timedelta(minutes=2),
                    last=100,
                    cumulative=100,
                    input_tokens=90,
                    cached_input_tokens=80,
                    output_tokens=10,
                    reasoning_output_tokens=5,
                ),
                self.user_event(start + timedelta(minutes=3), "Implement the plan."),
                self.token_event(
                    start + timedelta(minutes=4),
                    last=100,
                    cumulative=200,
                    input_tokens=180,
                    cached_input_tokens=160,
                    output_tokens=20,
                    reasoning_output_tokens=10,
                ),
                self.user_event(start + timedelta(minutes=5), "Continue"),
                self.token_event(
                    start + timedelta(minutes=6),
                    last=100,
                    cumulative=300,
                    input_tokens=270,
                    cached_input_tokens=240,
                    output_tokens=30,
                    reasoning_output_tokens=15,
                ),
                self.user_event(start + timedelta(minutes=10), second_task),
                self.token_event(
                    start + timedelta(minutes=11),
                    last=50,
                    cumulative=350,
                    input_tokens=315,
                    cached_input_tokens=280,
                    output_tokens=35,
                    reasoning_output_tokens=18,
                ),
                self.user_event(start + timedelta(minutes=12), "Implement the plan."),
                self.token_event(
                    start + timedelta(minutes=13),
                    last=50,
                    cumulative=400,
                    input_tokens=360,
                    cached_input_tokens=320,
                    output_tokens=40,
                    reasoning_output_tokens=20,
                ),
            ],
        )
        self.add_thread(
            connection,
            first_child_id,
            source=(
                '{"subagent":{"thread_spawn":{'
                f'"parent_thread_id":"{root_id}",'
                '"agent_path":"/root/verifier_1"}}}'
            ),
            tokens_used=600,
            recency=int((start + timedelta(minutes=3, seconds=30)).timestamp() * 1000),
            created_at=start + timedelta(minutes=3, seconds=30),
            events=[
                self.tool_event(start + timedelta(minutes=4), "exec", "secret-token"),
                self.token_event(
                    start + timedelta(minutes=5),
                    last=600,
                    cumulative=600,
                    input_tokens=580,
                    cached_input_tokens=550,
                    output_tokens=20,
                    reasoning_output_tokens=10,
                ),
                self.agent_event(
                    start + timedelta(minutes=6),
                    "Verified the dashboard implementation; secret=hidden-value",
                ),
            ],
        )
        self.add_thread(
            connection,
            second_child_id,
            source=(
                '{"subagent":{"thread_spawn":{'
                f'"parent_thread_id":"{root_id}",'
                '"agent_path":"/root/developer"}}}'
            ),
            tokens_used=200,
            recency=int((start + timedelta(minutes=12, seconds=30)).timestamp() * 1000),
            created_at=start + timedelta(minutes=12, seconds=30),
            events=[
                self.token_event(
                    start + timedelta(minutes=13),
                    last=200,
                    cumulative=200,
                    input_tokens=190,
                    cached_input_tokens=180,
                    output_tokens=10,
                    reasoning_output_tokens=4,
                ),
                self.agent_event(start + timedelta(minutes=14), "Implemented the tray filtering change"),
            ],
        )
        connection.executemany(
            "INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id) VALUES (?, ?)",
            ((root_id, first_child_id), (root_id, second_child_id)),
        )
        connection.commit()
        connection.close()

        result = self.run_script("--session", "aaaaaaaa", "--json", "--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)

        self.assertEqual(payload["mode"], "session")
        self.assertEqual(payload["tokens"]["total_tokens"], 1_200)
        self.assertEqual(sum(task["tokens"]["total_tokens"] for task in payload["tasks"]), 1_200)
        tasks = {task["title"]: task for task in payload["tasks"]}
        self.assertEqual(tasks[first_task]["main_tokens"], 300)
        self.assertEqual(tasks[first_task]["subagent_tokens"], 600)
        self.assertEqual(tasks[first_task]["share_percent"], 75.0)
        self.assertEqual(tasks[first_task]["phase_count"], 3)
        self.assertEqual(tasks[second_task]["main_tokens"], 100)
        self.assertEqual(tasks[second_task]["subagent_tokens"], 200)
        self.assertEqual(tasks[second_task]["share_percent"], 25.0)
        self.assertNotIn("Implement the plan.", tasks)
        self.assertNotIn("Continue", tasks)
        self.assertNotIn("AGENTS.md", result.stdout)
        self.assertNotIn("secret-token", result.stdout)
        self.assertNotIn("hidden-value", result.stdout)
        first_child = next(
            agent for agent in payload["agents"] if agent["thread_id"] == first_child_id
        )
        self.assertEqual(first_child["tools"], {"exec": 1})
        self.assertIn("[REDACTED]", first_child["result_summary"])

    def test_session_detail_text_prioritizes_task_usage(self) -> None:
        connection = self.create_database()
        root_id = "dddddddd-0000-0000-0000-000000000001"
        task = "Investigate expensive token usage"
        self.add_thread(
            connection,
            root_id,
            title="Task-focused report",
            tokens_used=250,
            recency=int(self.now.timestamp() * 1000),
            events=[
                self.user_event(self.now - timedelta(minutes=2), task),
                self.token_event(
                    self.now - timedelta(minutes=1),
                    last=250,
                    cumulative=250,
                ),
            ],
        )
        connection.commit()
        connection.close()

        result = self.run_script("--session", "dddddddd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Token usage by task", result.stdout)
        self.assertIn(task, result.stdout)
        self.assertIn("250 tokens", result.stdout)
        self.assertIn("100.00%", result.stdout)
        self.assertIn("Attribution:", result.stdout)

    def test_session_detail_rejects_ambiguous_missing_and_invalid_ids(self) -> None:
        connection = self.create_database()
        for suffix in ("1", "2"):
            self.add_thread(
                connection,
                f"abcdef12-0000-0000-0000-00000000000{suffix}",
                tokens_used=10,
                recency=100,
                events=[self.token_event(self.now, last=10, cumulative=10)],
            )
        connection.commit()
        connection.close()

        ambiguous = self.run_script("--session", "abcdef12")
        self.assertEqual(ambiguous.returncode, 1)
        self.assertIn("ambiguous", ambiguous.stderr)

        missing = self.run_script("--session", "deadbeef")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no session found", missing.stderr)

        invalid = self.run_script("--session", "short")
        self.assertEqual(invalid.returncode, 1)
        self.assertIn("at least 8", invalid.stderr)

    def test_session_detail_supplements_incomplete_rollout_from_state(self) -> None:
        connection = self.create_database()
        root_id = "eeeeeeee-0000-0000-0000-000000000001"
        task = "Recover incomplete usage"
        self.add_thread(
            connection,
            root_id,
            tokens_used=150,
            recency=int(self.now.timestamp() * 1000),
            events=[
                self.user_event(self.now - timedelta(minutes=2), task),
                self.token_event(
                    self.now - timedelta(minutes=1),
                    last=100,
                    cumulative=100,
                ),
            ],
        )
        connection.commit()
        connection.close()

        result = self.run_script("--session", "eeeeeeee", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["tokens"]["total_tokens"], 150)
        self.assertEqual(payload["tasks"][0]["tokens"]["total_tokens"], 150)
        self.assertTrue(payload["agents"][0]["used_state_fallback"])
        self.assertTrue(any("supplement" in warning for warning in payload["warnings"]))

    def test_session_mode_argument_conflicts_are_rejected(self) -> None:
        both = self.run_script("1", "--session", "aaaaaaaa")
        self.assertEqual(both.returncode, 2)
        self.assertIn("cannot be combined", both.stderr)

        verbose_list = self.run_script("1", "--verbose")
        self.assertEqual(verbose_list.returncode, 2)
        self.assertIn("requires --session", verbose_list.stderr)

    def test_reports_fewer_sessions_and_zero_window_without_failing(self) -> None:
        connection = self.create_database()
        outside = self.now - timedelta(days=8)
        self.add_thread(
            connection,
            "only-root",
            tokens_used=50,
            recency=100,
            events=[self.token_event(outside, last=50, cumulative=50)],
        )
        connection.commit()
        connection.close()

        result = self.run_script("3", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["returned_sessions"], 1)
        self.assertEqual(payload["window"]["total_tokens"], 0)
        self.assertEqual(payload["sessions"][0]["window_share_percent"], 0.0)
        self.assertTrue(any("only 1" in warning for warning in payload["warnings"]))

    def test_rejects_invalid_count_and_unsupported_database(self) -> None:
        invalid = self.run_script("0")
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("positive integer", invalid.stderr)

        sqlite3.connect(self.codex_home / "state_5.sqlite").close()
        unsupported = self.run_script("1")
        self.assertEqual(unsupported.returncode, 1)
        self.assertIn("no compatible Codex state database", unsupported.stderr)


if __name__ == "__main__":
    unittest.main()
