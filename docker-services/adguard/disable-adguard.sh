#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
SERVICE_NAME="adguardhome"
DNS_HELPER="${SCRIPT_DIR}/Ubuntu/uninstall-local-dns.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing required command: docker" >&2
  exit 1
fi

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  echo "Cannot access the Docker daemon. Check Docker or your permissions." >&2
  exit 1
fi

if [[ ! -x "${DNS_HELPER}" ]]; then
  echo "DNS helper is missing or not executable: ${DNS_HELPER}" >&2
  exit 1
fi

echo "Restoring Ubuntu DNS settings..."
if [[ "${EUID}" -eq 0 ]]; then
  "${DNS_HELPER}"
elif command -v sudo >/dev/null 2>&1; then
  sudo "${DNS_HELPER}"
else
  echo "Root access is required to restore local DNS, but sudo is unavailable." >&2
  exit 1
fi

echo "Disabling AdGuard Home..."
"${DOCKER[@]}" compose -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}"
"${DOCKER[@]}" compose -f "${COMPOSE_FILE}" ps --all "${SERVICE_NAME}"
