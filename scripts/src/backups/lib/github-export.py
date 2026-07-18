#!/usr/bin/env python3

import argparse
import json
import pathlib
import sys
import urllib.parse


def flatten_pages(document: list) -> list:
    if document and isinstance(document[0], list):
        return [item for page in document for item in page]
    return document


def repositories(source: pathlib.Path, owner: str | None = None) -> None:
    document = json.loads(source.read_text())
    for repository in flatten_pages(document):
        if owner and (repository.get("owner") or {}).get("login", "").casefold() != owner.casefold():
            continue
        values = [
            repository.get("full_name", ""),
            repository.get("clone_url", ""),
            "yes" if repository.get("has_wiki") else "no",
            repository.get("default_branch") or "",
            "yes" if repository.get("archived") else "no",
        ]
        if any("\t" in str(value) or "\n" in str(value) for value in values):
            raise RuntimeError("Unsafe repository metadata returned by GitHub")
        print("\t".join(values))


def gists(source: pathlib.Path) -> None:
    document = json.loads(source.read_text())
    for gist in flatten_pages(document):
        gist_id = gist.get("id", "")
        clone_url = gist.get("git_pull_url", "")
        if gist_id and clone_url:
            print(f"{gist_id}\t{clone_url}")


def branches(source: pathlib.Path) -> None:
    document = json.loads(source.read_text())
    pages = document if document and isinstance(document[0], list) else [document]
    for page in pages:
        for branch in page:
            name = branch.get("name", "")
            if name:
                print(f"{name}\t{urllib.parse.quote(name, safe='')}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("repositories", "gists", "branches"))
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("selector", nargs="?")
    args = parser.parse_args()
    try:
        if args.kind == "repositories":
            repositories(args.source, args.selector)
        else:
            globals()[args.kind](args.source)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
