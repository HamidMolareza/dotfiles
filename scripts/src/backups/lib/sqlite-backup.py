#!/usr/bin/env python3

import argparse
import os
import pathlib
import sqlite3
import sys


def quick_check(connection: sqlite3.Connection, label: str) -> None:
    rows = [row[0] for row in connection.execute("PRAGMA quick_check")]
    if rows != ["ok"]:
        raise RuntimeError(f"SQLite quick_check failed for {label}")


def backup(source: pathlib.Path, destination: pathlib.Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(f"SQLite source does not exist: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + f".tmp-{os.getpid()}")
    try:
        source_uri = f"file:{source.resolve()}?mode=ro"
        with sqlite3.connect(source_uri, uri=True, timeout=30) as source_db:
            with sqlite3.connect(temporary) as destination_db:
                source_db.backup(destination_db)
                quick_check(destination_db, str(destination))
        os.chmod(temporary, 0o600)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def check(source: pathlib.Path) -> None:
    source_uri = f"file:{source.resolve()}?mode=ro"
    with sqlite3.connect(source_uri, uri=True, timeout=30) as connection:
        quick_check(connection, str(source))


def main() -> int:
    parser = argparse.ArgumentParser(description="Create or verify a consistent SQLite backup")
    subparsers = parser.add_subparsers(dest="command", required=True)
    backup_parser = subparsers.add_parser("backup")
    backup_parser.add_argument("source", type=pathlib.Path)
    backup_parser.add_argument("destination", type=pathlib.Path)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("source", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "backup":
            backup(args.source, args.destination)
        else:
            check(args.source)
    except (OSError, sqlite3.Error, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
