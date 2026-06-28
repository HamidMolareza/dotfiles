#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
SERVICE_NAME="adguardhome"
DNS_HELPER="${SCRIPT_DIR}/Ubuntu/install-local-dns.sh"
ADGUARD_DNS="${ADGUARD_DNS:-127.0.0.1}"

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

echo "Enabling AdGuard Home..."
"${DOCKER[@]}" compose -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}"

if ! "${DOCKER[@]}" compose -f "${COMPOSE_FILE}" ps --status running --services "${SERVICE_NAME}" | grep -qx "${SERVICE_NAME}"; then
  echo "AdGuard Home did not reach the running state; local DNS was not changed." >&2
  exit 1
fi

echo "Configuring Ubuntu to use ${ADGUARD_DNS} for DNS..."
if [[ "${EUID}" -eq 0 ]]; then
  ADGUARD_DNS="${ADGUARD_DNS}" "${DNS_HELPER}"
elif command -v sudo >/dev/null 2>&1; then
  sudo env ADGUARD_DNS="${ADGUARD_DNS}" "${DNS_HELPER}"
else
  echo "Root access is required to configure local DNS, but sudo is unavailable." >&2
  exit 1
fi

"${DOCKER[@]}" compose -f "${COMPOSE_FILE}" ps "${SERVICE_NAME}"
