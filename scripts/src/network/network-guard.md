# network-guard

`network-guard` is a reusable preflight wrapper for commands that should only
run when the current network path is acceptable. It can be used directly from
the shell or embedded in other scripts.

## Commands

```bash
network-guard check
network-guard env
network-guard exec [--notice MESSAGE] -- COMMAND [ARGS...]
```

- `check` runs the preflight and exits `0` on pass, `1` on failure.
- `env` prints shell `export ...` lines only when the guard needs to inject
  proxy variables, such as WirePanel proxy mode. It prints nothing when the
  current state already passes without injection.
- `exec` runs the preflight, sets `NETWORK_GUARD_ACTIVE=1`, injects child
  proxy variables if needed, then replaces itself with `COMMAND`.

## Pass Conditions

At least one condition must pass:

- WirePanel is in `strict` or `lan` mode, connected, protected, and kill switch
  active.
- WirePanel is in `proxy` mode, connected, and the expected country check passes
  through either the existing session proxy or the WirePanel local proxy.
- The current environment already has a proxy variable with an explicit port,
  such as `HTTPS_PROXY=http://127.0.0.1:8911`, and `my-location` reports the
  expected country through it.
- `my-location --json` reports the expected country code.

The default expected country code is `US`.

## Proxy Injection

When WirePanel proxy mode is the passing condition and the current session does
not already have a proxy variable with an explicit port, the child command
receives proxy variables in this format, using the configured WirePanel
`proxyPort`:

```bash
export ALL_PROXY="socks5h://127.0.0.1:8911"
export all_proxy="socks5h://127.0.0.1:8911"
export http_proxy="http://127.0.0.1:8911"
export https_proxy="http://127.0.0.1:8911"
export HTTP_PROXY="http://127.0.0.1:8911"
export HTTPS_PROXY="http://127.0.0.1:8911"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
```

These variables are set only for the guarded child process. They do not mutate
the parent shell.

If the current session already has a proxy variable with any explicit port, such
as `ALL_PROXY=socks5h://127.0.0.1:<custom-port>`, `network-guard` preserves that
setting, prints no exports from `network-guard env`, and only verifies that the
resulting public egress country matches the expected country.

## Environment

- `NETWORK_GUARD_EXPECTED_COUNTRY_CODE`: expected fallback country code.
  Defaults to `US`.
- `NETWORK_GUARD_VERBOSE=1`: print diagnostic details.
- `NETWORK_GUARD_LOCATION_TIMEOUT_SECONDS`: timeout for `my-location`.
- `NETWORK_GUARD_WIREPANEL_SETTINGS_PATH`: override WirePanel settings path.
- `NETWORK_GUARD_MY_LOCATION_PATH`: override `my-location` path.
- `NETWORK_GUARD_ACTIVE=1`: set by `network-guard exec` to prevent recursive
  self-wrapping in child scripts.

Legacy `CODEX_GUARD_*` names are honored as fallbacks for compatibility.

## Shell Usage

Run a command through the guard:

```bash
network-guard exec -- codex-auth
network-guard exec -- curl https://example.com
```

Add a visible notice for wrapper commands:

```bash
network-guard exec \
  --notice "my-script: running through network guard" \
  -- my-script arg1 arg2
```

Check only:

```bash
network-guard check
```

## Bash Script Integration

Put this near the top of a script, after `set -Eeuo pipefail` and before any
network work:

```bash
if [[ "${NETWORK_GUARD_ACTIVE:-}" != "1" ]]; then
  exec network-guard exec -- "$0" "$@"
fi
```

If the script has local help output, keep help unguarded:

```bash
case "${1:-}" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

if [[ "${NETWORK_GUARD_ACTIVE:-}" != "1" ]]; then
  exec network-guard exec -- "$0" "$@"
fi
```

## Python Script Integration

```python
import os
import sys
from pathlib import Path


def ensure_network_guard() -> None:
    if os.environ.get("NETWORK_GUARD_ACTIVE") == "1":
        return
    if any(arg in {"-h", "--help"} for arg in sys.argv[1:]):
        return

    invocation = sys.argv[0] or "my-script"
    command = str(Path(invocation).resolve()) if "/" in invocation else invocation
    os.execvp("network-guard", ["network-guard", "exec", "--", command, *sys.argv[1:]])


ensure_network_guard()
```

## Current Users

- `codex`: thin wrapper that runs real Codex through `network-guard`, while
  bypassing `codex completion ...` so shell startup stays quiet.
- `codex-auth`: guarded by default for normal runs; `-h` and `--help` are
  unguarded.
