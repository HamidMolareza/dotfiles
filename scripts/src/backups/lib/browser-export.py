#!/usr/bin/env python3

import argparse
import configparser
import json
import pathlib
import re
import sys


def firefox_profile(root: pathlib.Path) -> None:
    parser = configparser.ConfigParser()
    parser.read(root / "profiles.ini")
    candidates = []
    for section in parser.sections():
        if not section.startswith("Profile"):
            continue
        path = parser.get(section, "Path", fallback="")
        if not path:
            continue
        profile = pathlib.Path(path)
        if parser.getboolean(section, "IsRelative", fallback=True):
            profile = root / profile
        candidates.append((parser.getboolean(section, "Default", fallback=False), profile))
    if not candidates:
        raise RuntimeError(f"No Firefox profile is declared in {root / 'profiles.ini'}")
    selected = next((path for default, path in candidates if default), candidates[0][1])
    print(selected.resolve())


def firefox_uuid(preferences: pathlib.Path, extension_id: str) -> None:
    pattern = re.compile(r'^user_pref\("extensions\.webextensions\.uuids",\s*"(.*)"\);$')
    for line in preferences.read_text(errors="replace").splitlines():
        match = pattern.match(line)
        if not match:
            continue
        encoded = json.loads('"' + match.group(1) + '"')
        mapping = json.loads(encoded)
        value = mapping.get(extension_id)
        if value:
            print(value)
            return
    raise RuntimeError(f"Firefox extension UUID is unavailable for {extension_id}")


def firefox_inventory(source: pathlib.Path, output: pathlib.Path) -> None:
    document = json.loads(source.read_text())
    addons = []
    for addon in document.get("addons", []):
        addons.append(
            {
                "id": addon.get("id"),
                "version": addon.get("version"),
                "active": addon.get("active"),
                "type": addon.get("type"),
                "signedState": addon.get("signedState"),
                "userDisabled": addon.get("userDisabled"),
                "permissions": (addon.get("userPermissions") or {}).get("permissions", []),
                "origins": (addon.get("userPermissions") or {}).get("origins", []),
            }
        )
    output.write_text(json.dumps({"browser": "firefox", "extensions": addons}, indent=2, sort_keys=True) + "\n")


def chromium_inventory(source: pathlib.Path, output: pathlib.Path) -> None:
    document = json.loads(source.read_text())
    extensions = []
    settings = document.get("extensions", {}).get("settings", {})
    for extension_id, setting in sorted(settings.items()):
        manifest = setting.get("manifest") or {}
        extensions.append(
            {
                "id": extension_id,
                "state": setting.get("state"),
                "from_webstore": setting.get("from_webstore"),
                "name": manifest.get("name"),
                "version": manifest.get("version"),
                "permissions": manifest.get("permissions", []),
                "host_permissions": manifest.get("host_permissions", []),
            }
        )
    output.write_text(json.dumps({"browser": "chromium", "extensions": extensions}, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    profile_parser = subparsers.add_parser("firefox-profile")
    profile_parser.add_argument("root", type=pathlib.Path)
    uuid_parser = subparsers.add_parser("firefox-uuid")
    uuid_parser.add_argument("preferences", type=pathlib.Path)
    uuid_parser.add_argument("extension_id")
    inventory_parser = subparsers.add_parser("firefox-inventory")
    inventory_parser.add_argument("source", type=pathlib.Path)
    inventory_parser.add_argument("output", type=pathlib.Path)
    chromium_parser = subparsers.add_parser("chromium-inventory")
    chromium_parser.add_argument("source", type=pathlib.Path)
    chromium_parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "firefox-profile":
            firefox_profile(args.root)
        elif args.command == "firefox-uuid":
            firefox_uuid(args.preferences, args.extension_id)
        elif args.command == "firefox-inventory":
            firefox_inventory(args.source, args.output)
        else:
            chromium_inventory(args.source, args.output)
    except (OSError, ValueError, RuntimeError, configparser.Error) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
