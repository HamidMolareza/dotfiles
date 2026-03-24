#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${1:-${ADGUARD_CONFIG_PATH:-${SCRIPT_DIR}/data/adguard/confdir/AdGuardHome.yaml}}"
COMPOSE_FILE="${ADGUARD_COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.yml}"
SERVICE_NAME="${ADGUARD_SERVICE_NAME:-adguardhome}"
DEFAULT_USERNAME="${ADGUARD_USERNAME:-}"
TEMP_INPUT=""
TEMP_OUTPUT=""

cleanup() {
  rm -f "${TEMP_INPUT:-}" "${TEMP_OUTPUT:-}"
}

need_cmd() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}"
    exit 1
  fi
}

can_use_sudo() {
  command -v sudo >/dev/null 2>&1
}

read_file() {
  local source_path="$1"

  if [[ -r "${source_path}" ]]; then
    cat "${source_path}"
    return
  fi

  if can_use_sudo; then
    sudo cat "${source_path}"
    return
  fi

  echo "Cannot read ${source_path}. Try running this script with sudo." >&2
  return 1
}

write_file() {
  local source_path="$1"
  local target_path="$2"

  if [[ -w "${target_path}" || ( ! -e "${target_path}" && -w "$(dirname "${target_path}")" ) ]]; then
    install -m 600 "${source_path}" "${target_path}"
    return
  fi

  if can_use_sudo; then
    sudo install -m 600 "${source_path}" "${target_path}"
    return
  fi

  echo "Cannot write ${target_path}. Try running this script with sudo." >&2
  return 1
}

backup_config() {
  local backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"

  if [[ -r "${CONFIG_PATH}" ]]; then
    cp -a "${CONFIG_PATH}" "${backup_path}"
  elif can_use_sudo; then
    sudo cp -a "${CONFIG_PATH}" "${backup_path}"
  else
    echo "Cannot back up ${CONFIG_PATH}." >&2
    return 1
  fi

  echo "Backup created: ${backup_path}"
}

stop_service_if_possible() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found; skipping stop/start."
    return
  fi

  if docker compose -f "${COMPOSE_FILE}" ps "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo "Stopping ${SERVICE_NAME} before editing config..."
    docker compose -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}" >/dev/null
    return
  fi

  if can_use_sudo && sudo docker compose -f "${COMPOSE_FILE}" ps "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo "Stopping ${SERVICE_NAME} before editing config..."
    sudo docker compose -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}" >/dev/null
    return
  fi

  echo "Could not stop ${SERVICE_NAME}; continuing without Docker control."
}

start_service_if_possible() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  if docker compose -f "${COMPOSE_FILE}" ps "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo "Starting ${SERVICE_NAME}..."
    docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}" >/dev/null
    return
  fi

  if can_use_sudo && sudo docker compose -f "${COMPOSE_FILE}" ps "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo "Starting ${SERVICE_NAME}..."
    sudo docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE_NAME}" >/dev/null
  fi
}

extract_first_username() {
  python3 - <<'PY'
import re
import sys

text = sys.stdin.read()
section_match = re.search(r'(?ms)^users:\s*\n(?P<body>(?:^[ \t].*\n?)*)', text)
if not section_match:
    sys.exit(0)

body = section_match.group('body')
match = re.search(r'(?m)^[ \t]*-\s*name:\s*(.+?)\s*$', body)
if not match:
    sys.exit(0)

value = match.group(1).strip().strip('"').strip("'")
print(value)
PY
}

prompt_for_password() {
  local first_password
  local second_password

  read -r -s -p "New AdGuard password: " first_password
  echo
  read -r -s -p "Repeat password: " second_password
  echo

  if [[ -z "${first_password}" ]]; then
    echo "Password cannot be empty." >&2
    return 1
  fi

  if [[ "${first_password}" != "${second_password}" ]]; then
    echo "Passwords do not match." >&2
    return 1
  fi

  printf '%s' "${first_password}"
}

generate_hash() {
  local username="$1"
  local password="$2"

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -B -C 10 -n -b "${username}" "${password}" | sed 's/^[^:]*://'
    return
  fi

  python3 - "${password}" <<'PY'
import crypt
import sys

password = sys.argv[1]

if not hasattr(crypt, "METHOD_BLOWFISH"):
    sys.stderr.write("Neither htpasswd nor Python bcrypt support is available.\n")
    sys.exit(1)

salt = crypt.mksalt(crypt.METHOD_BLOWFISH, rounds=2**10)
hashed = crypt.crypt(password, salt)
print(hashed)
PY
}

update_config() {
  local username="$1"
  local password_hash="$2"
  local input_path="$3"
  local output_path="$4"

  python3 - "${username}" "${password_hash}" "${input_path}" "${output_path}" <<'PY'
import pathlib
import re
import sys

username, password_hash, input_path, output_path = sys.argv[1:]
text = pathlib.Path(input_path).read_text()

inline_empty_users_pattern = re.compile(r'(?m)^users:\s*\[\s*\]\s*$')
if inline_empty_users_pattern.search(text):
    replacement = f"users:\n  - name: {username}\n    password: {password_hash}"
    text = inline_empty_users_pattern.sub(replacement, text, count=1)
    pathlib.Path(output_path).write_text(text)
    sys.exit(0)

users_pattern = re.compile(r'(?ms)^users:\s*\n(?P<body>(?:^[ \t].*\n?)*)')
name_pattern = re.compile(r'(?m)^(?P<indent>[ \t]*)-\s*name:\s*(?P<name>.+?)\s*$')

section = users_pattern.search(text)

if section:
    body = section.group('body')
    updated = False
    lines = body.splitlines()
    result = []
    i = 0

    while i < len(lines):
      line = lines[i]
      match = name_pattern.match(line)
      if not match:
        result.append(line)
        i += 1
        continue

      indent = match.group('indent')
      current_name = match.group('name').strip().strip('"').strip("'")
      result.append(line)
      i += 1

      if current_name != username:
        while i < len(lines) and not name_pattern.match(lines[i]):
          result.append(lines[i])
          i += 1
        continue

      password_written = False
      while i < len(lines) and not name_pattern.match(lines[i]):
        if re.match(rf'^{re.escape(indent)}[ \t]+password:\s*', lines[i]):
          result.append(f"{indent}  password: {password_hash}")
          password_written = True
        else:
          result.append(lines[i])
        i += 1

      if not password_written:
        result.append(f"{indent}  password: {password_hash}")
      updated = True

    if not updated:
      if result and result[-1] != "":
        result.append("")
      result.append(f"  - name: {username}")
      result.append(f"    password: {password_hash}")

    new_section = "users:\n" + "\n".join(result).rstrip() + "\n"
    text = text[:section.start()] + new_section + text[section.end():]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += f"users:\n  - name: {username}\n    password: {password_hash}\n"

pathlib.Path(output_path).write_text(text)
PY
}

main() {
  need_cmd "python3"

  if [[ ! -e "${CONFIG_PATH}" ]]; then
    echo "Config file not found: ${CONFIG_PATH}" >&2
    exit 1
  fi

  local config_text
  config_text="$(read_file "${CONFIG_PATH}")"

  local username="${DEFAULT_USERNAME}"
  if [[ -z "${username}" ]]; then
    username="$(printf '%s' "${config_text}" | extract_first_username || true)"
  fi
  if [[ -z "${username}" ]]; then
    username="admin"
  fi

  echo "Resetting AdGuard admin password for user: ${username}"
  local password
  password="$(prompt_for_password)"
  local password_hash
  password_hash="$(generate_hash "${username}" "${password}")"
  unset password

  backup_config
  stop_service_if_possible

  TEMP_INPUT="$(mktemp)"
  TEMP_OUTPUT="$(mktemp)"
  trap cleanup EXIT

  printf '%s' "${config_text}" > "${TEMP_INPUT}"
  update_config "${username}" "${password_hash}" "${TEMP_INPUT}" "${TEMP_OUTPUT}"
  write_file "${TEMP_OUTPUT}" "${CONFIG_PATH}"

  start_service_if_possible

  echo "Password reset complete."
  echo "You can now log in with username: ${username}"
}

main "$@"
