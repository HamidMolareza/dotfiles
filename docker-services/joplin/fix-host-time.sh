#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Fix Ubuntu host time for Joplin Server NTP drift issues.

Usage:
  fix-host-time.sh --status
  fix-host-time.sh --ntp [--server <ntp-host>]
  fix-host-time.sh --manual "YYYY-MM-DD HH:MM:SS"

Options:
  --status                 Show current time and NTP sync status.
  --ntp                    Enable NTP sync via systemd-timesyncd.
  --server <ntp-host>      Set a specific NTP server (LAN or internet).
  --manual "<datetime>"    Disable auto sync, set time manually, then sync HW clock.
  -h, --help               Show this help.
USAGE
}

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo "$0" "${ORIG_ARGS[@]}"
    else
      echo "This script needs root privileges. Re-run as root." >&2
      exit 1
    fi
  fi
}

is_ubuntu() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || [ "${ID_LIKE:-}" = "ubuntu" ]
    return $?
  fi
  return 1
}

set_ntp_server() {
  local server="$1"
  local conf="/etc/systemd/timesyncd.conf"

  if [ ! -f "$conf" ]; then
    echo "Missing $conf; cannot configure systemd-timesyncd." >&2
    exit 1
  fi

  if grep -qE '^\s*#?\s*NTP=' "$conf"; then
    sed -i "s|^\s*#\?\s*NTP=.*|NTP=${server}|" "$conf"
  else
    printf '\nNTP=%s\n' "$server" >> "$conf"
  fi

  if grep -qE '^\s*#?\s*FallbackNTP=' "$conf"; then
    sed -i 's|^\s*#\?\s*FallbackNTP=.*|FallbackNTP=|' "$conf"
  else
    printf 'FallbackNTP=\n' >> "$conf"
  fi
}

show_status() {
  timedatectl
}

MODE=""
NTP_SERVER=""
MANUAL_TIME=""
ORIG_ARGS=("$@")

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) MODE="status"; shift ;;
    --ntp) MODE="ntp"; shift ;;
    --server) NTP_SERVER="${2:-}"; shift 2 ;;
    --manual) MODE="manual"; MANUAL_TIME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if ! is_ubuntu; then
  echo "Warning: This script is tailored for Ubuntu/systemd-timesyncd." >&2
fi

case "$MODE" in
  status)
    show_status
    ;;
  ntp)
    need_root
    if [ -n "$NTP_SERVER" ]; then
      set_ntp_server "$NTP_SERVER"
    fi
    timedatectl set-ntp true
    systemctl restart systemd-timesyncd
    show_status
    ;;
  manual)
    if [ -z "$MANUAL_TIME" ]; then
      echo "Manual time is required." >&2
      usage
      exit 1
    fi
    need_root
    timedatectl set-ntp false
    timedatectl set-time "$MANUAL_TIME"
    if command -v hwclock >/dev/null 2>&1; then
      hwclock --systohc
    fi
    show_status
    ;;
  *)
    echo "No valid mode selected." >&2
    usage
    exit 1
    ;;
esac
