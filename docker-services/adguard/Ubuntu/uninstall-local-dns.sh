#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/adguard-ubuntu-dns"
RESOLVED_DROPIN_FILE="/etc/systemd/resolved.conf.d/99-adguard-local.conf"
NETWORKMANAGER_DROPIN_FILE="/etc/NetworkManager/conf.d/99-adguard-local-dns.conf"
RESOLV_CONF="/etc/resolv.conf"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run this script with sudo."
    exit 1
  fi
}

restart_if_present() {
  local service_name="$1"

  if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\.service"; then
    systemctl restart "${service_name}"
  fi
}

restore_file_or_remove() {
  local backup_path="$1"
  local target_path="$2"

  if [[ -e "${backup_path}" || -L "${backup_path}" ]]; then
    cp -a "${backup_path}" "${target_path}"
  else
    rm -f "${target_path}"
  fi
}

restore_resolv_conf() {
  local kind_file="${STATE_DIR}/resolv.conf.kind"

  if [[ ! -f "${kind_file}" ]]; then
    ln -snf /run/systemd/resolve/stub-resolv.conf "${RESOLV_CONF}"
    return
  fi

  case "$(cat "${kind_file}")" in
    symlink)
      if [[ -f "${STATE_DIR}/resolv.conf.target" ]]; then
        ln -snf "$(cat "${STATE_DIR}/resolv.conf.target")" "${RESOLV_CONF}"
      else
        ln -snf /run/systemd/resolve/stub-resolv.conf "${RESOLV_CONF}"
      fi
      ;;
    file)
      if [[ -e "${STATE_DIR}/resolv.conf.backup" ]]; then
        cp -a "${STATE_DIR}/resolv.conf.backup" "${RESOLV_CONF}"
      else
        rm -f "${RESOLV_CONF}"
      fi
      ;;
    *)
      rm -f "${RESOLV_CONF}"
      ;;
  esac
}

main() {
  require_root

  restore_file_or_remove "${STATE_DIR}/resolved.dropin.backup" "${RESOLVED_DROPIN_FILE}"
  restore_file_or_remove "${STATE_DIR}/networkmanager.dropin.backup" "${NETWORKMANAGER_DROPIN_FILE}"
  restore_resolv_conf

  restart_if_present "systemd-resolved"
  restart_if_present "NetworkManager"

  echo "Ubuntu DNS settings restored."
}

main "$@"
