#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_PATH="${1:-./data/adguard/confdir/AdGuardHome.yaml}"
DEFAULT_URL="http://localhost:3000"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

normalize_url() {
  local raw_address="$1"
  local host=""
  local port=""

  raw_address="$(trim "${raw_address}")"
  raw_address="${raw_address%\"}"
  raw_address="${raw_address#\"}"
  raw_address="${raw_address%\'}"
  raw_address="${raw_address#\'}"

  [[ -z "${raw_address}" ]] && return 1

  if [[ "${raw_address}" == *:* ]]; then
    host="${raw_address%:*}"
    port="${raw_address##*:}"
  else
    host="${raw_address}"
  fi

  host="$(trim "${host}")"
  port="$(trim "${port}")"

  if [[ -z "${port}" || ! "${port}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  case "${host}" in
    ""|"0.0.0.0"|"::"|"[::]"|"*" )
      host="localhost"
      ;;
  esac

  printf 'http://%s:%s\n' "${host}" "${port}"
}

extract_http_address() {
  local awk_script='
    /^http:[[:space:]]*$/ { in_http=1; next }
    in_http && /^[^[:space:]]/ { in_http=0 }
    in_http && /^[[:space:]]+address:[[:space:]]*/ {
      sub(/^[[:space:]]+address:[[:space:]]*/, "", $0)
      print
      exit
    }
  '

  if [[ -r "${CONFIG_PATH}" ]]; then
    awk "${awk_script}" "${CONFIG_PATH}"
    return
  fi

  if [[ -e "${CONFIG_PATH}" && -x "$(command -v sudo 2>/dev/null)" ]]; then
    sudo awk "${awk_script}" "${CONFIG_PATH}"
    return
  fi

  return 1
}

main() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "Config not found at ${CONFIG_PATH}."
    echo "Default admin page: ${DEFAULT_URL}"
    exit 0
  fi

  local raw_address
  raw_address="$(extract_http_address || true)"

  if [[ -n "${raw_address}" ]]; then
    local admin_url
    admin_url="$(normalize_url "${raw_address}" || true)"
    if [[ -n "${admin_url}" ]]; then
      echo "AdGuard admin page: ${admin_url}"
      exit 0
    fi
  fi

  if [[ ! -r "${CONFIG_PATH}" ]]; then
    echo "Could not read ${CONFIG_PATH} directly."
    echo "If prompted, allow sudo so the script can inspect the config."
  fi

  echo "Could not determine AdGuard admin address from ${CONFIG_PATH}."
  echo "Default admin page: ${DEFAULT_URL}"
}

main "$@"
