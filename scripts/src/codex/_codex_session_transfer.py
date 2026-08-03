#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUID_RE = re.compile(rf"^{UUID_PATTERN}$", re.IGNORECASE)
STATE_DB_RE = re.compile(r"state_(\d+)\.sqlite$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MANIFEST_SCHEMA = "codex-session-bundle"
MANIFEST_VERSION = 1
MULTI_MANIFEST_VERSION = 2
MAX_MANIFEST_SIZE = 8 * 1024 * 1024


class TransferError(RuntimeError):
    pass


@dataclass(frozen=True)
class ThreadRow:
    session_id: str
    parent_session_id: str | None
    depth: int
    rollout_path: Path
    archived: bool


@dataclass(frozen=True)
class SessionMeta:
    session_id: str
    parent_session_id: str | None
    cli_version: str | None


@dataclass(frozen=True)
class BundleEntry:
    session_id: str
    parent_session_id: str | None
    depth: int
    relative_path: PurePosixPath
    archived: bool
    size: int
    sha256: str
    thread_name: str | None
    cli_version: str | None


@dataclass(frozen=True)
class BundleManifest:
    version: int
    bundle_id: str | None
    root_session_ids: tuple[str, ...]
    entries: tuple[BundleEntry, ...]

    @property
    def backup_key(self) -> str:
        return self.bundle_id or self.root_session_ids[0]


@dataclass(frozen=True)
class RecentSession:
    session_id: str
    updated_at_ms: int
    archived: bool
    title: str
    cwd: str
    active: bool = False


def normalize_uuid(value: Any, label: str = "session id") -> str:
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        raise TransferError(f"{label} must be a complete UUID: {value!r}")
    return value.lower()


def codex_home_from(value: str | None) -> Path:
    raw = value or os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    return Path(raw).expanduser().resolve()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def new_bundle_id() -> str:
    return str(uuid.uuid4())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_private_directory(path: Path) -> None:
    missing: list[Path] = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    if cursor.is_symlink() or not cursor.is_dir():
        raise TransferError(f"directory path is unsafe: {cursor}")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        os.chmod(directory, 0o700)
    if path.is_symlink() or not path.is_dir():
        raise TransferError(f"directory path is unsafe: {path}")


def copy_stable(source: Path, destination: Path) -> tuple[int, str]:
    before = source.stat()
    ensure_private_directory(destination.parent)
    digest = hashlib.sha256()
    with source.open("rb") as reader, destination.open("xb") as writer:
        os.chmod(destination, 0o600)
        for chunk in iter(lambda: reader.read(1024 * 1024), b""):
            digest.update(chunk)
            writer.write(chunk)
        writer.flush()
        os.fsync(writer.fileno())
    after = source.stat()
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after:
        destination.unlink(missing_ok=True)
        raise TransferError(f"session file changed while it was being copied: {source}")
    return after.st_size, digest.hexdigest()


def readonly_connection(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in connection.execute(f"PRAGMA table_info({table})")}


def state_db_sort_key(path: Path) -> tuple[int, str]:
    match = STATE_DB_RE.fullmatch(path.name)
    return (int(match.group(1)) if match else -1, path.name)


def discover_state_database(codex_home: Path) -> Path:
    if not codex_home.is_dir():
        raise TransferError(f"Codex home does not exist: {codex_home}")
    candidates = sorted(codex_home.glob("state_*.sqlite"), key=state_db_sort_key, reverse=True)
    legacy = codex_home / "state.sqlite"
    if legacy.is_file():
        candidates.append(legacy)
    if not candidates:
        raise TransferError(f"no Codex state database found under {codex_home}")
    for candidate in candidates:
        try:
            with readonly_connection(candidate) as connection:
                if {"id", "rollout_path", "archived"} <= table_columns(connection, "threads") and {
                    "parent_thread_id", "child_thread_id"
                } <= table_columns(connection, "thread_spawn_edges"):
                    return candidate
        except sqlite3.Error:
            continue
    checked = ", ".join(item.name for item in candidates)
    raise TransferError(f"no compatible Codex state database found under {codex_home}; checked: {checked}")


def load_thread_tree(database: Path, root_id: str) -> list[ThreadRow]:
    try:
        with readonly_connection(database) as connection:
            rows = list(
                connection.execute(
                    """
WITH RECURSIVE tree(id, parent_id, depth, path) AS (
    SELECT id, NULL, 0, ',' || id || ',' FROM threads WHERE lower(id) = ?
    UNION ALL
    SELECT edge.child_thread_id, edge.parent_thread_id, tree.depth + 1,
           tree.path || edge.child_thread_id || ','
    FROM thread_spawn_edges AS edge
    JOIN tree ON lower(edge.parent_thread_id) = lower(tree.id)
    WHERE instr(lower(tree.path), ',' || lower(edge.child_thread_id) || ',') = 0
)
SELECT threads.id, tree.parent_id, tree.depth, threads.rollout_path, threads.archived
FROM tree JOIN threads ON lower(threads.id) = lower(tree.id)
ORDER BY tree.depth, threads.id
""",
                    (root_id,),
                )
            )
    except sqlite3.Error as exc:
        raise TransferError(f"could not read Codex state database: {exc}") from exc
    if not rows:
        raise TransferError(f"session is not present in the Codex state database: {root_id}")
    result: list[ThreadRow] = []
    seen: set[str] = set()
    for row in rows:
        session_id = normalize_uuid(row["id"], "database session id")
        if session_id in seen:
            raise TransferError(f"duplicate session in spawn tree: {session_id}")
        seen.add(session_id)
        parent = row["parent_id"]
        result.append(
            ThreadRow(
                session_id=session_id,
                parent_session_id=normalize_uuid(parent, "database parent session id") if parent else None,
                depth=int(row["depth"]),
                rollout_path=Path(str(row["rollout_path"])),
                archived=bool(row["archived"]),
            )
        )
    return result


def load_thread_forest(
    database: Path,
    requested_root_ids: Iterable[str],
) -> tuple[list[str], list[ThreadRow], list[str]]:
    requested: list[str] = []
    for value in requested_root_ids:
        session_id = normalize_uuid(value)
        if session_id not in requested:
            requested.append(session_id)
    if not requested:
        raise TransferError("at least one session id is required")

    trees = {root_id: load_thread_tree(database, root_id) for root_id in requested}
    selected_descendants = {
        root_id: {row.session_id for row in rows if row.session_id != root_id}
        for root_id, rows in trees.items()
    }
    effective_roots: list[str] = []
    dropped: list[str] = []
    for root_id in requested:
        ancestors = [
            candidate
            for candidate in requested
            if candidate != root_id and root_id in selected_descendants[candidate]
        ]
        if ancestors:
            if any(candidate in selected_descendants[root_id] for candidate in ancestors):
                raise TransferError(f"selected session trees contain a cycle involving {root_id}")
            dropped.append(root_id)
        else:
            effective_roots.append(root_id)

    forest: list[ThreadRow] = []
    seen: set[str] = set()
    for root_id in effective_roots:
        for row in trees[root_id]:
            if row.session_id in seen:
                raise TransferError(
                    f"selected session trees overlap at {row.session_id}; Codex spawn edges are ambiguous"
                )
            seen.add(row.session_id)
            forest.append(row)
    return effective_roots, forest, dropped


def _title_expression(columns: set[str]) -> str:
    candidates = [
        f"NULLIF(TRIM({column}), '')"
        for column in ("name", "title", "preview", "first_user_message")
        if column in columns
    ]
    candidates.append("id")
    if len(candidates) == 1:
        return candidates[0]
    return "COALESCE(" + ", ".join(candidates) + ")"


def load_recent_root_sessions(database: Path, codex_home: Path, limit: int) -> tuple[list[RecentSession], int]:
    if limit <= 0:
        raise TransferError("recent-session limit must be greater than zero")
    try:
        with readonly_connection(database) as connection:
            columns = table_columns(connection, "threads")
            recency = next(
                (column for column in ("recency_at_ms", "updated_at_ms", "created_at_ms") if column in columns),
                None,
            )
            recency_expression = f"COALESCE({recency}, 0)" if recency else "0"
            cwd_expression = "COALESCE(cwd, '')" if "cwd" in columns else "''"
            source_filter = ""
            if "thread_source" in columns:
                source_filter = "AND COALESCE(lower(thread_source), 'user') <> 'subagent'"
            elif "source" in columns:
                source_filter = "AND (source IS NULL OR source NOT LIKE '%subagent%')"
            rows = list(
                connection.execute(
                    f"""
SELECT id,
       {_title_expression(columns)} AS effective_title,
       {cwd_expression} AS cwd,
       {recency_expression} AS recency_ms,
       archived
FROM threads AS thread
WHERE NOT EXISTS (
    SELECT 1 FROM thread_spawn_edges AS edge
    WHERE lower(edge.child_thread_id) = lower(thread.id)
)
{source_filter}
ORDER BY recency_ms DESC, id DESC
LIMIT ?
""",
                    (limit,),
                )
            )
    except sqlite3.Error as exc:
        raise TransferError(f"could not list recent Codex sessions: {exc}") from exc

    ids = {normalize_uuid(row["id"], "database session id") for row in rows}
    names, malformed = load_effective_names(codex_home / "session_index.jsonl", ids)
    sessions = [
        RecentSession(
            session_id=normalize_uuid(row["id"], "database session id"),
            updated_at_ms=max(int(row["recency_ms"] or 0), 0),
            archived=bool(row["archived"]),
            title=names.get(normalize_uuid(row["id"], "database session id"), str(row["effective_title"] or row["id"])),
            cwd=str(row["cwd"] or ""),
        )
        for row in rows
    ]
    return sessions, malformed


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def rollout_candidates(codex_home: Path, session_id: str) -> list[Path]:
    result: list[Path] = []
    suffixes = (f"{session_id}.jsonl", f"{session_id}.jsonl.zst")
    for directory in (codex_home / "sessions", codex_home / "archived_sessions"):
        if directory.is_symlink():
            raise TransferError(f"session directory must not be a symlink: {directory}")
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if not path.name.endswith(suffixes):
                continue
            if path.is_symlink() or not path.is_file():
                raise TransferError(f"matching local rollout path is unsafe: {path}")
            result.append(path.resolve())
    return sorted(set(result), key=lambda item: (item.suffix == ".zst", str(item)))


def resolve_rollout(codex_home: Path, row: ThreadRow) -> Path:
    roots = (codex_home / "sessions", codex_home / "archived_sessions")
    configured = row.rollout_path.expanduser()
    if not configured.is_absolute():
        configured = codex_home / configured
    configured = configured.resolve()
    options = [configured]
    if configured.suffix == ".jsonl":
        options.append(Path(f"{configured}.zst"))
    valid = [
        item.resolve()
        for item in options
        if item.is_file()
        and not item.is_symlink()
        and any(is_relative_to(item.resolve(), root.resolve()) for root in roots if root.exists())
    ]
    if not valid:
        valid = rollout_candidates(codex_home, row.session_id)
    if not valid:
        raise TransferError(f"rollout file is missing for session {row.session_id}: {row.rollout_path}")
    plain = [item for item in valid if item.suffix != ".zst"]
    choices = plain or valid
    if len(choices) != 1:
        rendered = ", ".join(str(item) for item in choices)
        raise TransferError(f"ambiguous rollout files for session {row.session_id}: {rendered}")
    return choices[0]


def first_line(path: Path) -> str:
    if path.suffix != ".zst":
        with path.open("r", encoding="utf-8") as handle:
            return handle.readline()
    executable = shutil.which("zstd")
    if not executable:
        raise TransferError(f"zstd is required to read compressed session file: {path}")
    process = subprocess.Popen(
        [executable, "-dc", "--", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    try:
        assert process.stdout is not None
        line = process.stdout.readline()
        if not line:
            assert process.stderr is not None
            error = process.stderr.read().strip()
            process.wait()
            raise TransferError(f"could not read compressed session metadata from {path}: {error or 'empty file'}")
        return line
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait()


def read_session_meta(path: Path) -> SessionMeta:
    try:
        record = json.loads(first_line(path))
    except (json.JSONDecodeError, UnicodeDecodeError, OSError) as exc:
        raise TransferError(f"invalid first record in session file {path}: {exc}") from exc
    payload = record.get("payload") if isinstance(record, dict) else None
    if record.get("type") != "session_meta" or not isinstance(payload, dict):
        raise TransferError(f"first record is not session_meta in {path}")
    parent = payload.get("parent_thread_id")
    return SessionMeta(
        session_id=normalize_uuid(payload.get("id"), "session_meta id"),
        parent_session_id=normalize_uuid(parent, "session_meta parent_thread_id") if parent else None,
        cli_version=str(payload["cli_version"]) if payload.get("cli_version") is not None else None,
    )


def load_effective_names(index_path: Path, wanted: set[str] | None = None) -> tuple[dict[str, str], int]:
    names: dict[str, str] = {}
    malformed = 0
    if index_path.is_symlink():
        raise TransferError(f"session index must not be a symlink: {index_path}")
    if not index_path.exists():
        return names, malformed
    if not index_path.is_file():
        raise TransferError(f"session index is not a regular file: {index_path}")
    with index_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                record = json.loads(line)
                session_id = normalize_uuid(record.get("id"), "session index id")
                name = record.get("thread_name")
                if not isinstance(name, str) or not name:
                    raise TransferError("thread_name is not a non-empty string")
            except (json.JSONDecodeError, TransferError):
                malformed += 1
                continue
            if wanted is None or session_id in wanted:
                names[session_id] = name
    return names, malformed


def active_session_ids(codex_home: Path, helper: Path) -> set[str]:
    if not helper.is_file():
        raise TransferError(f"active-session helper is missing: {helper}")
    completed = subprocess.run(
        [str(helper), "--codex-home", str(codex_home), "active", "--json"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise TransferError(f"could not verify active Codex sessions: {detail}")
    try:
        groups = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise TransferError(f"active-session helper returned invalid JSON: {exc}") from exc
    if not isinstance(groups, list):
        raise TransferError("active-session helper returned an unexpected JSON value")
    result: set[str] = set()
    for group in groups:
        if not isinstance(group, dict):
            continue
        if group.get("protected") is True:
            current_id = os.environ.get("CODEX_THREAD_ID", "")
            if UUID_RE.fullmatch(current_id):
                result.add(current_id.lower())
                continue
            raise TransferError(
                "could not determine the current protected Codex session id from CODEX_THREAD_ID"
            )
        candidates: list[Any] = list(group.get("thread_ids") or [])
        session = group.get("session")
        if isinstance(session, dict):
            candidates.append(session.get("thread_id"))
        for value in candidates:
            if isinstance(value, str) and UUID_RE.fullmatch(value):
                result.add(value.lower())
    return result


def validate_inactive(session_ids: Iterable[str], codex_home: Path, helper: Path) -> None:
    matches = sorted(set(session_ids) & active_session_ids(codex_home, helper))
    if matches:
        raise TransferError(f"refusing to transfer active session(s): {', '.join(matches)}")


def manifest_entry_to_dict(entry: BundleEntry) -> dict[str, Any]:
    return {
        "session_id": entry.session_id,
        "parent_session_id": entry.parent_session_id,
        "depth": entry.depth,
        "relative_path": entry.relative_path.as_posix(),
        "archived": entry.archived,
        "size": entry.size,
        "sha256": entry.sha256,
        "thread_name": entry.thread_name,
        "cli_version": entry.cli_version,
    }


def write_json_file(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8") as handle:
        os.chmod(path, 0o600)
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def parse_bundle_path(value: Any, session_id: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise TransferError(f"relative_path is missing for session {session_id}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise TransferError(f"unsafe relative_path for session {session_id}: {value!r}")
    if not path.parts or path.parts[0] not in {"sessions", "archived_sessions"}:
        raise TransferError(f"relative_path must be under sessions/ or archived_sessions/: {value!r}")
    if not (path.name.endswith(f"{session_id}.jsonl") or path.name.endswith(f"{session_id}.jsonl.zst")):
        raise TransferError(f"relative_path filename does not match session {session_id}: {value!r}")
    return path


def load_manifest(bundle: Path) -> BundleManifest:
    manifest_path = bundle / "manifest.json"
    if bundle.is_symlink() or not bundle.is_dir():
        raise TransferError(f"export path is not a regular directory: {bundle}")
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise TransferError(f"bundle manifest is missing or unsafe: {manifest_path}")
    if manifest_path.stat().st_size > MAX_MANIFEST_SIZE:
        raise TransferError(f"bundle manifest is larger than {MAX_MANIFEST_SIZE} bytes")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TransferError(f"could not read bundle manifest: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("schema") != MANIFEST_SCHEMA:
        raise TransferError("unsupported bundle manifest schema or version")
    version = manifest.get("version")
    if type(version) is not int:
        raise TransferError("unsupported bundle manifest schema or version")
    if version == MANIFEST_VERSION:
        bundle_id = None
        root_ids = [normalize_uuid(manifest.get("root_session_id"), "root_session_id")]
    elif version == MULTI_MANIFEST_VERSION:
        bundle_id = normalize_uuid(manifest.get("bundle_id"), "bundle_id")
        raw_roots = manifest.get("root_session_ids")
        if not isinstance(raw_roots, list) or not raw_roots:
            raise TransferError("version 2 bundle manifest has no root_session_ids")
        root_ids = [normalize_uuid(value, "root_session_ids entry") for value in raw_roots]
        if len(set(root_ids)) != len(root_ids):
            raise TransferError("version 2 bundle manifest contains duplicate root session ids")
    else:
        raise TransferError("unsupported bundle manifest schema or version")
    raw_entries = manifest.get("sessions")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise TransferError("bundle manifest has no sessions")
    entries: list[BundleEntry] = []
    ids: set[str] = set()
    paths: set[PurePosixPath] = set()
    for raw in raw_entries:
        if not isinstance(raw, dict):
            raise TransferError("bundle session entry must be an object")
        session_id = normalize_uuid(raw.get("session_id"), "manifest session_id")
        parent_value = raw.get("parent_session_id")
        parent_id = normalize_uuid(parent_value, "manifest parent_session_id") if parent_value else None
        if session_id in ids:
            raise TransferError(f"duplicate session id in manifest: {session_id}")
        relative_path = parse_bundle_path(raw.get("relative_path"), session_id)
        if relative_path in paths:
            raise TransferError(f"duplicate relative_path in manifest: {relative_path}")
        depth = raw.get("depth")
        size = raw.get("size")
        digest = raw.get("sha256")
        archived = raw.get("archived")
        name = raw.get("thread_name")
        cli_version = raw.get("cli_version")
        if not isinstance(depth, int) or depth < 0:
            raise TransferError(f"invalid depth for session {session_id}")
        if not isinstance(size, int) or size < 0:
            raise TransferError(f"invalid size for session {session_id}")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise TransferError(f"invalid sha256 for session {session_id}")
        if not isinstance(archived, bool) or archived != (relative_path.parts[0] == "archived_sessions"):
            raise TransferError(f"archived status disagrees with relative_path for session {session_id}")
        if name is not None and (not isinstance(name, str) or not name):
            raise TransferError(f"invalid thread_name for session {session_id}")
        if cli_version is not None and not isinstance(cli_version, str):
            raise TransferError(f"invalid cli_version for session {session_id}")
        entries.append(BundleEntry(session_id, parent_id, depth, relative_path, archived, size, digest, name, cli_version))
        ids.add(session_id)
        paths.add(relative_path)
    roots = [entry for entry in entries if entry.parent_session_id is None]
    if any(entry.depth != 0 for entry in roots) or {entry.session_id for entry in roots} != set(root_ids):
        raise TransferError("manifest roots must exactly match the declared root session ids at depth zero")
    by_id = {entry.session_id: entry for entry in entries}
    for entry in entries:
        if entry.session_id in root_ids:
            continue
        if entry.parent_session_id not in by_id:
            raise TransferError(f"parent is missing from manifest for session {entry.session_id}")
        parent = by_id[entry.parent_session_id]
        if entry.depth != parent.depth + 1:
            raise TransferError(f"invalid depth relationship for session {entry.session_id}")
        visited = {entry.session_id}
        cursor = entry
        while cursor.parent_session_id is not None:
            if cursor.parent_session_id in visited:
                raise TransferError(f"cycle detected in manifest at session {entry.session_id}")
            visited.add(cursor.parent_session_id)
            cursor = by_id[cursor.parent_session_id]
        if cursor.session_id not in root_ids:
            raise TransferError(f"session {entry.session_id} is not connected to a declared manifest root")
    return BundleManifest(
        version=int(version),
        bundle_id=bundle_id,
        root_session_ids=tuple(root_ids),
        entries=tuple(entries),
    )


def validate_bundle_payloads(bundle: Path, entries: Iterable[BundleEntry]) -> None:
    bundle_real = bundle.resolve()
    for entry in entries:
        path = bundle.joinpath(*entry.relative_path.parts)
        if path.is_symlink() or not path.is_file():
            raise TransferError(f"bundle payload is missing, not regular, or a symlink: {entry.relative_path}")
        if not is_relative_to(path.resolve(), bundle_real):
            raise TransferError(f"bundle payload escapes export path: {entry.relative_path}")
        if path.stat().st_size != entry.size:
            raise TransferError(f"size mismatch for bundle payload: {entry.relative_path}")
        if sha256_file(path) != entry.sha256:
            raise TransferError(f"sha256 mismatch for bundle payload: {entry.relative_path}")
        meta = read_session_meta(path)
        if meta.session_id != entry.session_id:
            raise TransferError(f"session_meta id mismatch for bundle payload: {entry.relative_path}")
        if entry.parent_session_id is not None and meta.parent_session_id != entry.parent_session_id:
            raise TransferError(f"session_meta parent mismatch for bundle payload: {entry.relative_path}")


def append_names(index_path: Path, entries: Iterable[tuple[str, str]], timestamp: str) -> int:
    records = [
        json.dumps({"id": session_id, "thread_name": name, "updated_at": timestamp}, ensure_ascii=False)
        for session_id, name in entries
    ]
    if not records:
        return index_path.stat().st_size if index_path.exists() else 0
    ensure_private_directory(index_path.parent)
    original_size = index_path.stat().st_size if index_path.exists() else 0
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(index_path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        data = (("\n".join(records)) + "\n").encode("utf-8")
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return original_size


def truncate_file(path: Path, size: int) -> None:
    if not path.exists() and size == 0:
        return
    with path.open("r+b") as handle:
        handle.truncate(size)
        handle.flush()
        os.fsync(handle.fileno())


def safe_destination_path(codex_home: Path, relative_path: PurePosixPath) -> Path:
    target = codex_home.joinpath(*relative_path.parts)
    cursor = codex_home
    for part in relative_path.parts[:-1]:
        cursor = cursor / part
        if cursor.is_symlink():
            raise TransferError(f"destination path contains a symlink: {cursor}")
        if cursor.exists() and not cursor.is_dir():
            raise TransferError(f"destination path component is not a directory: {cursor}")
    if target.is_symlink():
        raise TransferError(f"destination rollout path is a symlink: {target}")
    return target
