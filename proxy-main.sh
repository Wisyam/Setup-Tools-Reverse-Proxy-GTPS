#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/.env"
WG_INTERFACE="wg0"

MODE=""
CONFIG_PATH="$DEFAULT_CONFIG_PATH"

BACKUP_DIR=""
WG_CONF_BACKUP=""
CHANGED_WG=0

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --config /path/.env --mode apply|verify

Options:
  --config <path>   Path to config .env file (default: ${DEFAULT_CONFIG_PATH})
  --mode <mode>     apply or verify
  -h, --help        Show this help
USAGE
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must run as root"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "Missing value for --config"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "Missing value for --mode"
        MODE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$MODE" ]] || die "--mode is required"
  case "$MODE" in
    apply|verify) ;;
    *) die "Invalid --mode '$MODE'. Use apply or verify." ;;
  esac
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH"

  # shellcheck disable=SC1090
  source "$CONFIG_PATH"

  WG_PORT="${WG_PORT:-51820}"
  WG_GATE_IP="${WG_GATE_IP:-10.0.0.1/24}"
  WG_MAIN_IP="${WG_MAIN_IP:-10.0.0.2/24}"
  WG_GATE_PUBLIC_KEY="${WG_GATE_PUBLIC_KEY:-}"
  GATE_PUBLIC_IP="${GATE_PUBLIC_IP:-}"
  WG_HANDSHAKE_TIMEOUT_SEC="${WG_HANDSHAKE_TIMEOUT_SEC:-90}"

  WG_GATE_IP_ADDR="${WG_GATE_IP%/*}"
  WG_MAIN_IP_ADDR="${WG_MAIN_IP%/*}"
}

validate_config() {
  local missing=()
  [[ -n "$WG_GATE_PUBLIC_KEY" ]] || missing+=("WG_GATE_PUBLIC_KEY")
  [[ -n "$GATE_PUBLIC_IP" ]] || missing+=("GATE_PUBLIC_IP")

  if (( ${#missing[@]} > 0 )); then
    die "Missing required config value(s): ${missing[*]}"
  fi

  [[ "$WG_PORT" =~ ^[0-9]+$ ]] || die "WG_PORT must be numeric"
}

check_ubuntu_2404() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only"
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "This script requires Ubuntu 24.04"
}

require_command() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
  done
}

ensure_backup_dir() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  BACKUP_DIR="/var/backups/wysps-proxy/${ts}"
  mkdir -p "$BACKUP_DIR"

  if [[ -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
    WG_CONF_BACKUP="${BACKUP_DIR}/${WG_INTERFACE}.conf.backup"
    cp "/etc/wireguard/${WG_INTERFACE}.conf" "$WG_CONF_BACKUP"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y wireguard iproute2 iputils-ping
}

generate_wg_keys_if_missing() {
  install -d -m 700 /etc/wireguard

  if [[ ! -f /etc/wireguard/privatekey || ! -f /etc/wireguard/publickey ]]; then
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    log "Generated WireGuard keypair"
  fi
}

render_wg_conf() {
  local private_key
  private_key=$(< /etc/wireguard/privatekey)

  cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address = ${WG_MAIN_IP}
PrivateKey = ${private_key}
SaveConfig = false

[Peer]
PublicKey = ${WG_GATE_PUBLIC_KEY}
Endpoint = ${GATE_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${WG_GATE_IP_ADDR}/32
PersistentKeepalive = 25
EOF

  chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
}

restore_wg_config() {
  systemctl disable --now "wg-quick@${WG_INTERFACE}" >/dev/null 2>&1 || true

  if [[ -n "$WG_CONF_BACKUP" && -f "$WG_CONF_BACKUP" ]]; then
    cp "$WG_CONF_BACKUP" "/etc/wireguard/${WG_INTERFACE}.conf"
    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
    systemctl enable --now "wg-quick@${WG_INTERFACE}" >/dev/null 2>&1 || true
    log "Restored ${WG_INTERFACE}.conf from backup"
  else
    rm -f "/etc/wireguard/${WG_INTERFACE}.conf"
  fi
}

wait_for_handshake() {
  local peer_key="$1"
  local timeout_sec="$2"
  local waited=0

  while (( waited < timeout_sec )); do
    local hs
    hs=$(wg show "$WG_INTERFACE" latest-handshakes | awk -v key="$peer_key" '$1 == key {print $2}')
    if [[ -n "$hs" && "$hs" -gt 0 ]]; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done

  return 1
}

setup_wireguard() {
  generate_wg_keys_if_missing
  render_wg_conf

  systemctl enable --now "wg-quick@${WG_INTERFACE}"
  CHANGED_WG=1

  if ! wait_for_handshake "$WG_GATE_PUBLIC_KEY" "$WG_HANDSHAKE_TIMEOUT_SEC"; then
    restore_wg_config
    die "WireGuard handshake with gate peer failed within ${WG_HANDSHAKE_TIMEOUT_SEC}s"
  fi

  if ! ping -c 2 -W 2 "$WG_GATE_IP_ADDR" >/dev/null 2>&1; then
    restore_wg_config
    die "Ping to gate tunnel IP ${WG_GATE_IP_ADDR} failed"
  fi

  log "WireGuard tunnel established and ping check passed"
}

verify_mode() {
  local failed=0

  if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    warn "WireGuard interface ${WG_INTERFACE} is not active"
    failed=1
  fi

  if ! wg show "$WG_INTERFACE" >/dev/null 2>&1; then
    warn "wg show ${WG_INTERFACE} failed"
    failed=1
  fi

  if ! ping -c 2 -W 2 "$WG_GATE_IP_ADDR" >/dev/null 2>&1; then
    warn "Ping to gate tunnel IP ${WG_GATE_IP_ADDR} failed"
    failed=1
  fi

  if (( failed == 1 )); then
    die "Verification failed"
  fi

  log "Verification passed"
}

rollback_changes() {
  warn "Rolling back partial changes"

  if (( CHANGED_WG == 1 )); then
    restore_wg_config || true
  fi
}

on_err() {
  local exit_code=$?
  local line_no=$1

  if [[ "$MODE" == "apply" ]]; then
    warn "Failure at line ${line_no} (exit ${exit_code})"
    rollback_changes
  fi

  exit "$exit_code"
}

apply_mode() {
  check_ubuntu_2404
  ensure_backup_dir
  install_packages
  setup_wireguard

  log "Apply completed successfully"
  log "Backup artifacts stored at ${BACKUP_DIR}"
  log "Main public WireGuard key: $(< /etc/wireguard/publickey)"
}

main() {
  parse_args "$@"
  load_config
  validate_config

  trap 'on_err $LINENO' ERR

  require_root
  require_command apt-get wg wg-quick ip ping systemctl

  case "$MODE" in
    apply) apply_mode ;;
    verify) verify_mode ;;
  esac
}

main "$@"
