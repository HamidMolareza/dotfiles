#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/adguard-ubuntu-dns"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/99-adguard-local.conf"
NETWORKMANAGER_DROPIN_DIR="/etc/NetworkManager/conf.d"
NETWORKMANAGER_DROPIN_FILE="${NETWORKMANAGER_DROPIN_DIR}/99-adguard-local-dns.conf"
RESOLV_CONF="/etc/resolv.conf"
ADGUARD_DNS="${ADGUARD_DNS:-127.0.0.1}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run this script with sudo."
    exit 1
  fi
}

backup_if_present() {
  local source_path="$1"
  local backup_path="$2"

  if [[ -e "${backup_path}" || -L "${backup_path}" ]]; then
    return
  fi

  if [[ -e "${source_path}" || -L "${source_path}" ]]; then
    cp -a "${source_path}" "${backup_path}"
  fi
}

backup_resolv_conf() {
  mkdir -p "${STATE_DIR}"

  if [[ -f "${STATE_DIR}/resolv.conf.kind" ]]; then
    return
  fi

  if [[ -L "${RESOLV_CONF}" ]]; then
    printf 'symlink\n' > "${STATE_DIR}/resolv.conf.kind"
    readlink "${RESOLV_CONF}" > "${STATE_DIR}/resolv.conf.target"
    return
  fi

  if [[ -e "${RESOLV_CONF}" ]]; then
    printf 'file\n' > "${STATE_DIR}/resolv.conf.kind"
    cp -a "${RESOLV_CONF}" "${STATE_DIR}/resolv.conf.backup"
    return
  fi

  printf 'missing\n' > "${STATE_DIR}/resolv.conf.kind"
}

restart_if_present() {
  local service_name="$1"

  if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\.service"; then
    systemctl restart "${service_name}"
  fi
}

write_resolved_dropin() {
  mkdir -p "${RESOLVED_DROPIN_DIR}"
  cat > "${RESOLVED_DROPIN_FILE}" <<EOF
[Resolve]
DNS=${ADGUARD_DNS}
FallbackDNS=
Domains=~.
DNSStubListener=no
EOF
  chmod 644 "${RESOLVED_DROPIN_FILE}"
}

write_networkmanager_dropin() {
  mkdir -p "${NETWORKMANAGER_DROPIN_DIR}"
  cat > "${NETWORKMANAGER_DROPIN_FILE}" <<'EOF'
[main]
dns=none
rc-manager=unmanaged
EOF
  chmod 644 "${NETWORKMANAGER_DROPIN_FILE}"
}

write_resolv_conf() {
  cat > "${RESOLV_CONF}" <<EOF
nameserver ${ADGUARD_DNS}
options edns0
EOF
  chmod 644 "${RESOLV_CONF}"
}

warn_if_dns_not_listening() {
  if ! command -v ss >/dev/null 2>&1; then
    return
  fi

  if ss -H -lntu '( sport = :53 )' | grep -q ':53'; then
    return
  fi

  echo "Warning: nothing appears to be listening on port 53 yet."
  echo "Make sure AdGuard Home is running before relying on DNS."
}

main() {
  require_root
  mkdir -p "${STATE_DIR}"

  backup_if_present "${RESOLVED_DROPIN_FILE}" "${STATE_DIR}/resolved.dropin.backup"
  backup_if_present "${NETWORKMANAGER_DROPIN_FILE}" "${STATE_DIR}/networkmanager.dropin.backup"
  backup_resolv_conf

  write_resolved_dropin
  write_networkmanager_dropin
  write_resolv_conf

  systemctl enable --now systemd-resolved
  restart_if_present "systemd-resolved"
  restart_if_present "NetworkManager"
  warn_if_dns_not_listening

  echo "Ubuntu is now configured to use ${ADGUARD_DNS} for DNS."
  echo "Test it with: resolvectl query example.com"
}

main "$@"
