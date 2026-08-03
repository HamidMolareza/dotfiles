from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CODEX_DIR = Path(__file__).resolve().parents[1]
EXPORT_SCRIPT = CODEX_DIR / "codex-session-export"
IMPORT_SCRIPT = CODEX_DIR / "codex-session-import"
ROOT_ID = "01901234-5678-7abc-9def-0123456789ab"
CHILD_ID = "01901234-5678-7abc-9def-0123456789ac"
GRANDCHILD_ID = "01901234-5678-7abc-9def-0123456789ad"
SECOND_ROOT_ID = "01901234-5678-7abc-9def-0123456789ae"
ORPHAN_AGENT_ID = "01901234-5678-7abc-9def-0123456789af"


class CodexSessionTransferTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="codex-session-transfer-test-"))
        self.addCleanup(shutil.rmtree, self.temp_dir)
        self.source_home = self.temp_dir / "source"
        self.destination_home = self.temp_dir / "destination"
        self.source_home.mkdir(mode=0o700)

    def create_database(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.source_home / "state_5.sqlite")
        connection.executescript(
            """
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    rollout_path TEXT NOT NULL,
    archived INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL DEFAULT '',
    thread_source TEXT
);
CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id TEXT NOT NULL PRIMARY KEY
);
"""
        )
        return connection

    def add_thread(
        self,
        connection: sqlite3.Connection,
        session_id: str,
        *,
        parent_id: str | None = None,
        archived: bool = False,
        name: str | None = None,
        compressed: bool = False,
        body: str = "payload",
        updated_at_ms: int = 0,
        thread_source: str | None = None,
    ) -> Path:
        base = self.source_home / ("archived_sessions" if archived else "sessions") / "2026" / "08" / "03"
        base.mkdir(parents=True, exist_ok=True)
        plain = base / f"rollout-2026-08-03T00-00-00-{session_id}.jsonl"
        meta = {
            "timestamp": "2026-08-03T00:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "parent_thread_id": parent_id,
                "cli_version": "0.146.0",
            },
        }
        plain.write_text(json.dumps(meta) + "\n" + body + "\n", encoding="utf-8")
        stored = plain
        if compressed:
            if shutil.which("zstd") is None:
                self.skipTest("zstd is not installed")
            subprocess.run(["zstd", "-q", "--rm", str(plain)], check=True)
            stored = Path(f"{plain}.zst")
        connection.execute(
            """
INSERT INTO threads(id, rollout_path, archived, updated_at_ms, title, cwd, thread_source)
VALUES (?, ?, ?, ?, ?, ?, ?)
""",
            (
                session_id,
                str(plain),
                int(archived),
                updated_at_ms,
                name or session_id,
                "/tmp/project",
                thread_source or ("subagent" if parent_id else "user"),
            ),
        )
        if parent_id is not None:
            connection.execute(
                "INSERT INTO thread_spawn_edges(parent_thread_id, child_thread_id) VALUES (?, ?)",
                (parent_id, session_id),
            )
        if name is not None:
            with (self.source_home / "session_index.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": session_id, "thread_name": name, "updated_at": "2026-08-03T00:00:00Z"}) + "\n")
        return stored

    def make_tree(self, *, archived_root: bool = False, compressed_child: bool = False) -> None:
        with self.create_database() as connection:
            self.add_thread(connection, ROOT_ID, archived=archived_root, name="Portable root")
            self.add_thread(connection, CHILD_ID, parent_id=ROOT_ID, name="Child agent", compressed=compressed_child)
            self.add_thread(connection, GRANDCHILD_ID, parent_id=CHILD_ID)

    def run_export(self, bundle: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_export_ids(bundle, [ROOT_ID], *extra)

    def run_export_ids(self, bundle: Path, session_ids: list[str], *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(EXPORT_SCRIPT), *session_ids, str(bundle), "--codex-home", str(self.source_home), *extra],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_import(self, bundle: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(IMPORT_SCRIPT), str(bundle), "--codex-home", str(self.destination_home), *extra],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def export_bundle(self) -> Path:
        bundle = self.temp_dir / "bundle"
        result = self.run_export(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        return bundle

    def load_export_module(self):
        module_name = f"codex_session_export_test_{id(self)}"
        loader = importlib.machinery.SourceFileLoader(module_name, str(EXPORT_SCRIPT))
        spec = importlib.util.spec_from_loader(module_name, loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        sys.path.insert(0, str(CODEX_DIR))
        self.addCleanup(lambda: sys.modules.pop(module_name, None))
        self.addCleanup(lambda: sys.path.remove(str(CODEX_DIR)))
        loader.exec_module(module)
        return module

    def test_exports_and_imports_complete_spawn_tree_with_names(self) -> None:
        self.make_tree()
        bundle = self.export_bundle()

        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["root_session_id"], ROOT_ID)
        self.assertEqual([item["session_id"] for item in manifest["sessions"]], [ROOT_ID, CHILD_ID, GRANDCHILD_ID])
        self.assertEqual([item["depth"] for item in manifest["sessions"]], [0, 1, 2])
        self.assertEqual(manifest["sessions"][1]["thread_name"], "Child agent")
        self.assertNotIn(str(self.source_home), (bundle / "manifest.json").read_text(encoding="utf-8"))

        result = self.run_import(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"codex resume {ROOT_ID}", result.stdout)
        imported = list((self.destination_home / "sessions").rglob("*.jsonl"))
        self.assertEqual(len(imported), 3)
        names = (self.destination_home / "session_index.jsonl").read_text(encoding="utf-8")
        self.assertIn("Portable root", names)
        self.assertIn("Child agent", names)
        self.assertEqual(os.stat(imported[0]).st_mode & 0o777, 0o600)

    def test_dry_runs_do_not_mutate_filesystem(self) -> None:
        self.make_tree()
        bundle = self.temp_dir / "bundle"
        result = self.run_export(bundle, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(bundle.exists())

        bundle = self.export_bundle()
        result = self.run_import(bundle, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination_home.exists())

    def test_export_rejects_existing_path_and_invalid_uuid(self) -> None:
        self.make_tree()
        bundle = self.temp_dir / "bundle"
        bundle.mkdir()
        result = self.run_export(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)

        result = subprocess.run(
            [str(EXPORT_SCRIPT), "1234", str(self.temp_dir / "other"), "--codex-home", str(self.source_home)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("complete UUID", result.stderr)

    def test_export_rejects_missing_database_and_missing_rollout(self) -> None:
        empty_home = self.temp_dir / "empty"
        empty_home.mkdir()
        result = subprocess.run(
            [str(EXPORT_SCRIPT), ROOT_ID, str(self.temp_dir / "bundle"), "--codex-home", str(empty_home)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Codex state database", result.stderr)

        with self.create_database() as connection:
            missing = self.source_home / "sessions" / f"rollout-{ROOT_ID}.jsonl"
            connection.execute(
                "INSERT INTO threads(id, rollout_path, archived) VALUES (?, ?, 0)",
                (ROOT_ID, str(missing)),
            )
        result = self.run_export(self.temp_dir / "missing-bundle")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollout file is missing", result.stderr)

    def test_export_rejects_current_active_session(self) -> None:
        self.make_tree()
        environment = os.environ.copy()
        environment["CODEX_THREAD_ID"] = ROOT_ID
        result = subprocess.run(
            [
                str(EXPORT_SCRIPT),
                ROOT_ID,
                str(self.temp_dir / "active-bundle"),
                "--codex-home",
                str(self.source_home),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active session", result.stderr)

    def test_import_rejects_current_active_session_without_writing(self) -> None:
        self.make_tree()
        bundle = self.export_bundle()
        environment = os.environ.copy()
        environment["CODEX_THREAD_ID"] = ROOT_ID
        result = subprocess.run(
            [str(IMPORT_SCRIPT), str(bundle), "--codex-home", str(self.destination_home)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active session", result.stderr)
        self.assertFalse(self.destination_home.exists())

    def test_compressed_and_archived_payloads_are_supported(self) -> None:
        with self.create_database() as connection:
            self.add_thread(connection, ROOT_ID, archived=True, name="Archived root", compressed=True)
        bundle = self.export_bundle()
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(manifest["sessions"][0]["archived"])
        self.assertTrue(manifest["sessions"][0]["relative_path"].endswith(".jsonl.zst"))

        result = self.run_import(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"codex unarchive {ROOT_ID}", result.stdout)
        self.assertEqual(len(list((self.destination_home / "archived_sessions").rglob("*.zst"))), 1)

    def test_explicit_multi_root_bundle_exports_and_imports_as_version_two(self) -> None:
        with self.create_database() as connection:
            self.add_thread(connection, ROOT_ID, name="First root", updated_at_ms=300)
            self.add_thread(connection, CHILD_ID, parent_id=ROOT_ID, name="First child", updated_at_ms=200)
            self.add_thread(connection, SECOND_ROOT_ID, name="Archived second", archived=True, updated_at_ms=100)
        bundle = self.temp_dir / "multi-bundle"
        exported = self.run_export_ids(bundle, [ROOT_ID, SECOND_ROOT_ID])
        self.assertEqual(exported.returncode, 0, exported.stderr)

        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(manifest["root_session_ids"], [ROOT_ID, SECOND_ROOT_ID])
        self.assertRegex(manifest["bundle_id"], r"^[0-9a-f-]{36}$")
        self.assertEqual(len(manifest["sessions"]), 3)

        imported = self.run_import(bundle)
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertIn("Imported 2 root session(s)", imported.stdout)
        self.assertIn(f"codex resume {ROOT_ID}", imported.stdout)
        self.assertIn(f"codex unarchive {SECOND_ROOT_ID}", imported.stdout)
        self.assertEqual(len(list((self.destination_home / "sessions").rglob("*.jsonl"))), 2)
        self.assertEqual(len(list((self.destination_home / "archived_sessions").rglob("*.jsonl"))), 1)

        repeated = self.run_import(bundle)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertIn("3 identical file(s)", repeated.stdout)

        first_root = next((self.destination_home / "sessions").rglob(f"*{ROOT_ID}.jsonl"))
        first_root.write_text(first_root.read_text(encoding="utf-8") + "local conflict\n", encoding="utf-8")
        forced = self.run_import(bundle, "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        backup_manifests = list(
            (self.destination_home / "session-import-backups" / manifest["bundle_id"]).glob("*/backup-manifest.json")
        )
        self.assertEqual(len(backup_manifests), 1)
        backup = json.loads(backup_manifests[0].read_text(encoding="utf-8"))
        self.assertEqual(backup["root_session_ids"], [ROOT_ID, SECOND_ROOT_ID])

    def test_overlapping_selected_roots_are_collapsed_to_single_version_one_bundle(self) -> None:
        self.make_tree()
        bundle = self.temp_dir / "overlapping-bundle"
        result = self.run_export_ids(bundle, [CHILD_ID, ROOT_ID])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already included", result.stderr)
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["root_session_id"], ROOT_ID)
        self.assertEqual(len(manifest["sessions"]), 3)

    def test_recent_picker_source_lists_roots_and_excludes_orphan_subagents(self) -> None:
        with self.create_database() as connection:
            self.add_thread(connection, ROOT_ID, name="Older root", updated_at_ms=100)
            self.add_thread(connection, CHILD_ID, parent_id=ROOT_ID, updated_at_ms=500)
            self.add_thread(connection, SECOND_ROOT_ID, name="New archived root", archived=True, updated_at_ms=300)
            self.add_thread(
                connection,
                ORPHAN_AGENT_ID,
                name="Orphan subagent",
                updated_at_ms=400,
                thread_source="subagent",
            )

        module = self.load_export_module()
        database = module.discover_state_database(self.source_home)
        sessions, malformed = module.load_recent_root_sessions(database, self.source_home, 20)
        self.assertEqual(malformed, 0)
        self.assertEqual([session.session_id for session in sessions], [SECOND_ROOT_ID, ROOT_ID])
        self.assertTrue(sessions[0].archived)
        self.assertEqual(sessions[0].title, "New archived root")
        limited, _ = module.load_recent_root_sessions(database, self.source_home, 1)
        self.assertEqual([session.session_id for session in limited], [SECOND_ROOT_ID])

    def test_numbered_fallback_supports_multiple_ranges_and_install_message(self) -> None:
        module = self.load_export_module()
        sessions = [
            module.RecentSession(ROOT_ID, 300, False, "First", "/tmp/first"),
            module.RecentSession(CHILD_ID, 200, False, "Active", "/tmp/active", active=True),
            module.RecentSession(SECOND_ROOT_ID, 100, True, "Archived", "/tmp/archive"),
        ]
        output = io.StringIO()
        selected = module.fallback_picker(sessions, io.StringIO("2\n1,3\n"), output)
        self.assertEqual(selected, [ROOT_ID, SECOND_ROOT_ID])
        self.assertIn("python3-questionary", output.getvalue())
        self.assertIn("not selectable", output.getvalue())
        self.assertIn("is active", output.getvalue())

        with self.assertRaises(module.SelectionCancelled):
            module.fallback_picker(sessions, io.StringIO("\n"), io.StringIO())

    def test_questionary_picker_disables_active_sessions_and_supports_multiple(self) -> None:
        module = self.load_export_module()
        sessions = [
            module.RecentSession(ROOT_ID, 300, False, "First", "/tmp/first"),
            module.RecentSession(CHILD_ID, 200, False, "Active", "/tmp/active", active=True),
            module.RecentSession(SECOND_ROOT_ID, 100, True, "Archived", "/tmp/archive"),
        ]

        class FakeQuestion:
            def ask(self):
                return [ROOT_ID, SECOND_ROOT_ID]

        class FakeQuestionary:
            choices = None

            class Choice:
                def __init__(self, **kwargs):
                    self.__dict__.update(kwargs)

            @classmethod
            def checkbox(cls, _message, **kwargs):
                cls.choices = kwargs["choices"]
                return FakeQuestion()

        selected = module.questionary_picker(sessions, FakeQuestionary)
        self.assertEqual(selected, [ROOT_ID, SECOND_ROOT_ID])
        self.assertIsNone(FakeQuestionary.choices[0].disabled)
        self.assertEqual(FakeQuestionary.choices[1].disabled, "currently active")

    def test_version_two_manifest_rejects_duplicate_declared_roots(self) -> None:
        with self.create_database() as connection:
            self.add_thread(connection, ROOT_ID)
            self.add_thread(connection, SECOND_ROOT_ID)
        bundle = self.temp_dir / "multi-bundle"
        result = self.run_export_ids(bundle, [ROOT_ID, SECOND_ROOT_ID])
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest_path = bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["root_session_ids"] = [ROOT_ID, ROOT_ID]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        imported = self.run_import(bundle)
        self.assertNotEqual(imported.returncode, 0)
        self.assertIn("duplicate root", imported.stderr)

    def test_identical_import_is_noop_and_different_content_requires_force(self) -> None:
        self.make_tree()
        bundle = self.export_bundle()
        first = self.run_import(bundle)
        self.assertEqual(first.returncode, 0, first.stderr)
        index = self.destination_home / "session_index.jsonl"
        initial_index = index.read_bytes()

        second = self.run_import(bundle)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("3 identical", second.stdout)
        self.assertEqual(index.read_bytes(), initial_index)

        root_file = next((self.destination_home / "sessions").rglob(f"*{ROOT_ID}.jsonl"))
        root_file.write_text(root_file.read_text(encoding="utf-8") + "local change\n", encoding="utf-8")
        rejected = self.run_import(bundle)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("--force", rejected.stderr)

        forced = self.run_import(bundle, "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        backups = list((self.destination_home / "session-import-backups" / ROOT_ID).glob("*/backup-manifest.json"))
        self.assertEqual(len(backups), 1)
        self.assertNotIn("local change", root_file.read_text(encoding="utf-8"))

    def test_name_conflict_requires_force_and_is_replaced_append_only(self) -> None:
        self.make_tree()
        bundle = self.export_bundle()
        first = self.run_import(bundle)
        self.assertEqual(first.returncode, 0, first.stderr)
        index = self.destination_home / "session_index.jsonl"
        with index.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"id": ROOT_ID, "thread_name": "Local name", "updated_at": "2026-08-03T01:00:00Z"}) + "\n")

        rejected = self.run_import(bundle)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("local name differs", rejected.stderr)
        forced = self.run_import(bundle, "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        latest = [json.loads(line) for line in index.read_text(encoding="utf-8").splitlines() if json.loads(line)["id"] == ROOT_ID][-1]
        self.assertEqual(latest["thread_name"], "Portable root")

    def test_import_rejects_hash_mismatch_path_traversal_and_symlink(self) -> None:
        self.make_tree()
        bundle = self.export_bundle()
        manifest_path = bundle / "manifest.json"
        original = json.loads(manifest_path.read_text(encoding="utf-8"))

        tampered = json.loads(json.dumps(original))
        tampered["sessions"][0]["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(tampered), encoding="utf-8")
        result = self.run_import(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)

        traversing = json.loads(json.dumps(original))
        traversing["sessions"][0]["relative_path"] = f"sessions/../rollout-{ROOT_ID}.jsonl"
        manifest_path.write_text(json.dumps(traversing), encoding="utf-8")
        result = self.run_import(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe relative_path", result.stderr)

        manifest_path.write_text(json.dumps(original), encoding="utf-8")
        relative = Path(original["sessions"][0]["relative_path"])
        payload = bundle / relative
        real_payload = self.temp_dir / "outside.jsonl"
        payload.rename(real_payload)
        payload.symlink_to(real_payload)
        result = self.run_import(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
