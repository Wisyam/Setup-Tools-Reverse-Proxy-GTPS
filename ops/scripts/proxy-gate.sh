#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/proxy/.env"
WG_INTERFACE="wg0"
PROXY_CHAIN="WYSPS_PROXY_RATE_LIMIT"

MODE=""
CONFIG_PATH="${DEFAULT_CONFIG_PATH}"

BACKUP_DIR=""
SSH_BACKUP_FILE=""
WG_CONF_BACKUP=""
OLD_SSH_PORT="22"
CHANGED_SSH=0
CHANGED_WG=0
CHANGED_IPTABLES=0

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

  GTPS_UDP_PORT="${GTPS_UDP_PORT:-17091}"
  WG_PORT="${WG_PORT:-51820}"
  WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
  WG_GATE_IP="${WG_GATE_IP:-10.0.0.1/24}"
  WG_MAIN_IP="${WG_MAIN_IP:-10.0.0.2/24}"
  SSH_NEW_PORT="${SSH_NEW_PORT:-8922}"
  RATE_LIMIT_PPS="${RATE_LIMIT_PPS:-50}"
  RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-100}"
  MAIN_PUBLIC_IP="${MAIN_PUBLIC_IP:-}"
  MAIN_SSH_USER="${MAIN_SSH_USER:-}"
  MAIN_SSH_PORT="${MAIN_SSH_PORT:-22}"
  MAIN_WG_PUBLIC_KEY="${MAIN_WG_PUBLIC_KEY:-}"
  ADMIN_USER="${ADMIN_USER:-wyspsadmin}"
  ADMIN_PUBLIC_KEY="${ADMIN_PUBLIC_KEY:-}"
  ADMIN_AUTHORIZED_KEYS_FILE="${ADMIN_AUTHORIZED_KEYS_FILE:-}"
  FIREWALL_READY="${FIREWALL_READY:-false}"
  PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-}"
  WG_HANDSHAKE_TIMEOUT_SEC="${WG_HANDSHAKE_TIMEOUT_SEC:-90}"

  WG_GATE_IP_ADDR="${WG_GATE_IP%/*}"
  WG_MAIN_IP_ADDR="${WG_MAIN_IP%/*}"
}

validate_apply_config() {
  local missing=()
  [[ -n "$MAIN_PUBLIC_IP" ]] || missing+=("MAIN_PUBLIC_IP")
  [[ -n "$MAIN_SSH_USER" ]] || missing+=("MAIN_SSH_USER")
  [[ -n "$MAIN_WG_PUBLIC_KEY" ]] || missing+=("MAIN_WG_PUBLIC_KEY")

  if (( ${#missing[@]} > 0 )); then
    die "Missing required config value(s): ${missing[*]}"
  fi
}

validate_common_config() {
  [[ "$GTPS_UDP_PORT" =~ ^[0-9]+$ ]] || die "GTPS_UDP_PORT must be numeric"
  [[ "$WG_PORT" =~ ^[0-9]+$ ]] || die "WG_PORT must be numeric"
  [[ "$SSH_NEW_PORT" =~ ^[0-9]+$ ]] || die "SSH_NEW_PORT must be numeric"
  [[ "$RATE_LIMIT_PPS" =~ ^[0-9]+$ ]] || die "RATE_LIMIT_PPS must be numeric"
  [[ "$RATE_LIMIT_BURST" =~ ^[0-9]+$ ]] || die "RATE_LIMIT_BURST must be numeric"
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
  log "Backup directory: $BACKUP_DIR"
}

backup_state() {
  SSH_BACKUP_FILE="${BACKUP_DIR}/sshd_config.backup"
  cp /etc/ssh/sshd_config "$SSH_BACKUP_FILE"

  cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.backup"

  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "${BACKUP_DIR}/iptables.before.rules"
  fi

  if [[ -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
    WG_CONF_BACKUP="${BACKUP_DIR}/${WG_INTERFACE}.conf.backup"
    cp "/etc/wireguard/${WG_INTERFACE}.conf" "$WG_CONF_BACKUP"
  fi

  OLD_SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config || true)
  OLD_SSH_PORT="${OLD_SSH_PORT:-22}"
}

confirm_firewall_checkpoint() {
  cat <<CHECKLIST
[Firewall checkpoint]
Complete in Tencent Cloud console before continuing:
1) Ingress UDP allow port ${GTPS_UDP_PORT}
2) Ingress UDP allow port ${WG_PORT}
3) Ingress TCP allow current SSH bootstrap port (${OLD_SSH_PORT})
CHECKLIST

  if [[ "$FIREWALL_READY" == "true" ]]; then
    log "Firewall checkpoint bypassed via FIREWALL_READY=true"
    return
  fi

  if [[ ! -t 0 ]]; then
    die "Non-interactive shell detected. Set FIREWALL_READY=true after manual dashboard validation."
  fi

  local answer=""
  read -r -p "Type CONFIRM_FIREWALL_READY to continue: " answer
  [[ "$answer" == "CONFIRM_FIREWALL_READY" ]] || die "Firewall checkpoint not confirmed"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y wireguard iptables iptables-persistent netfilter-persistent iproute2 iputils-ping openssh-server netcat-openbsd
}

ensure_admin_user() {
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$ADMIN_USER"
    log "Created admin user: $ADMIN_USER"
  else
    log "Admin user exists: $ADMIN_USER"
  fi

  usermod -aG sudo "$ADMIN_USER" || true

  local auth_keys_file="/home/${ADMIN_USER}/.ssh/authorized_keys"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"

  if [[ -n "$ADMIN_PUBLIC_KEY" ]]; then
    printf '%s\n' "$ADMIN_PUBLIC_KEY" > "$auth_keys_file"
  elif [[ -n "$ADMIN_AUTHORIZED_KEYS_FILE" && -f "$ADMIN_AUTHORIZED_KEYS_FILE" ]]; then
    cp "$ADMIN_AUTHORIZED_KEYS_FILE" "$auth_keys_file"
  elif [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$auth_keys_file"
  else
    warn "No admin SSH key source found. Set ADMIN_PUBLIC_KEY or ADMIN_AUTHORIZED_KEYS_FILE."
  fi

  if [[ -f "$auth_keys_file" ]]; then
    chown "$ADMIN_USER:$ADMIN_USER" "$auth_keys_file"
    chmod 600 "$auth_keys_file"
  fi
}

ensure_sshd_option() {
  local key="$1"
  local value="$2"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" /etc/ssh/sshd_config; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" /etc/ssh/sshd_config
  else
    printf '%s %s\n' "$key" "$value" >> /etc/ssh/sshd_config
  fi
}

restart_ssh_service() {
  if systemctl list-unit-files | grep -q '^ssh.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd.service'; then
    systemctl restart sshd
  else
    die "Unable to find ssh or sshd service"
  fi
}

wait_for_ssh_port() {
  local target_port="$1"
  local retries=15

  for ((i=1; i<=retries; i++)); do
    if ss -lnt | awk '{print $4}' | grep -Eq "(^|:)$target_port$"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restore_sshd_config() {
  if [[ -n "$SSH_BACKUP_FILE" && -f "$SSH_BACKUP_FILE" ]]; then
    cp "$SSH_BACKUP_FILE" /etc/ssh/sshd_config
    restart_ssh_service || true
    log "Restored sshd_config from backup"
  fi
}

harden_ssh() {
  ensure_sshd_option "Port" "$SSH_NEW_PORT"
  ensure_sshd_option "PasswordAuthentication" "no"
  ensure_sshd_option "PubkeyAuthentication" "yes"
  ensure_sshd_option "PermitRootLogin" "prohibit-password"

  sshd -t -f /etc/ssh/sshd_config
  restart_ssh_service

  if ! wait_for_ssh_port "$SSH_NEW_PORT"; then
    restore_sshd_config
    die "New SSH port ${SSH_NEW_PORT} is not listening after restart"
  fi

  CHANGED_SSH=1
  log "SSH hardened: Port=${SSH_NEW_PORT}, PasswordAuthentication=no"
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
Address = ${WG_GATE_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${private_key}
SaveConfig = false

[Peer]
PublicKey = ${MAIN_WG_PUBLIC_KEY}
AllowedIPs = ${WG_MAIN_IP_ADDR}/32
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
  require_command wg wg-quick

  generate_wg_keys_if_missing
  render_wg_conf

  systemctl enable --now "wg-quick@${WG_INTERFACE}"
  CHANGED_WG=1

  if ! wait_for_handshake "$MAIN_WG_PUBLIC_KEY" "$WG_HANDSHAKE_TIMEOUT_SEC"; then
    restore_wg_config
    die "WireGuard handshake with main peer failed within ${WG_HANDSHAKE_TIMEOUT_SEC}s"
  fi

  log "WireGuard tunnel established"
}

ensure_ip_forward() {
  if grep -Eq '^[[:space:]]*#?[[:space:]]*net.ipv4.ip_forward=' /etc/sysctl.conf; then
    sed -ri 's|^[[:space:]]*#?[[:space:]]*net.ipv4.ip_forward=.*|net.ipv4.ip_forward=1|' /etc/sysctl.conf
  else
    printf '\nnet.ipv4.ip_forward=1\n' >> /etc/sysctl.conf
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -p >/dev/null
}

resolve_public_interface() {
  if [[ -n "$PUBLIC_INTERFACE" ]]; then
    echo "$PUBLIC_INTERFACE"
    return
  fi

  local iface
  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  [[ -n "$iface" ]] || die "Unable to detect public interface. Set PUBLIC_INTERFACE in config."
  echo "$iface"
}

iptables_ensure() {
  local table="$1"
  local chain="$2"
  shift 2

  if ! iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    iptables -t "$table" -A "$chain" "$@"
  fi
}

iptables_delete_if_exists() {
  local table="$1"
  local chain="$2"
  shift 2

  while iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; do
    iptables -t "$table" -D "$chain" "$@"
  done
}

remove_proxy_rules() {
  local pub_if
  pub_if=$(resolve_public_interface)

  iptables_delete_if_exists nat PREROUTING -i "$pub_if" -p udp --dport "$GTPS_UDP_PORT" -m comment --comment WYSPS_PROXY_DNAT -j DNAT --to-destination "${WG_MAIN_IP_ADDR}:${GTPS_UDP_PORT}"
  iptables_delete_if_exists nat POSTROUTING -o "$pub_if" -p udp -s "$WG_MAIN_IP_ADDR" --sport "$GTPS_UDP_PORT" -m comment --comment WYSPS_PROXY_MASQUERADE -j MASQUERADE

  iptables_delete_if_exists filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment WYSPS_PROXY_FWD_ESTABLISHED -j ACCEPT
  iptables_delete_if_exists filter FORWARD -i "$pub_if" -o "$WG_INTERFACE" -p udp -d "$WG_MAIN_IP_ADDR" --dport "$GTPS_UDP_PORT" -m comment --comment WYSPS_PROXY_FWD_TO_CHAIN -j "$PROXY_CHAIN"
  iptables_delete_if_exists filter FORWARD -i "$WG_INTERFACE" -o "$pub_if" -p udp -s "$WG_MAIN_IP_ADDR" --sport "$GTPS_UDP_PORT" -m comment --comment WYSPS_PROXY_FWD_RETURN -j ACCEPT

  if iptables -t filter -L "$PROXY_CHAIN" >/dev/null 2>&1; then
    iptables -t filter -F "$PROXY_CHAIN" || true
    iptables -t filter -X "$PROXY_CHAIN" || true
  fi
}

setup_iptables() {
  local pub_if
  pub_if=$(resolve_public_interface)

  if ! iptables -t filter -L "$PROXY_CHAIN" >/dev/null 2>&1; then
    iptables -t filter -N "$PROXY_CHAIN"
  fi

  iptables -t filter -F "$PROXY_CHAIN"

  iptables_ensure filter "$PROXY_CHAIN" \
    -m hashlimit \
    --hashlimit-mode srcip \
    --hashlimit-name WYSPS_PROXY_HASHLIMIT \
    --hashlimit-upto "${RATE_LIMIT_PPS}/second" \
    --hashlimit-burst "$RATE_LIMIT_BURST" \
    -m comment --comment WYSPS_PROXY_RATE_ACCEPT \
    -j ACCEPT

  iptables_ensure filter "$PROXY_CHAIN" \
    -m comment --comment WYSPS_PROXY_RATE_DROP \
    -j DROP

  iptables_ensure nat PREROUTING \
    -i "$pub_if" -p udp --dport "$GTPS_UDP_PORT" \
    -m comment --comment WYSPS_PROXY_DNAT \
    -j DNAT --to-destination "${WG_MAIN_IP_ADDR}:${GTPS_UDP_PORT}"

  iptables_ensure filter FORWARD \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment WYSPS_PROXY_FWD_ESTABLISHED \
    -j ACCEPT

  iptables_ensure filter FORWARD \
    -i "$pub_if" -o "$WG_INTERFACE" -p udp -d "$WG_MAIN_IP_ADDR" --dport "$GTPS_UDP_PORT" \
    -m comment --comment WYSPS_PROXY_FWD_TO_CHAIN \
    -j "$PROXY_CHAIN"

  iptables_ensure filter FORWARD \
    -i "$WG_INTERFACE" -o "$pub_if" -p udp -s "$WG_MAIN_IP_ADDR" --sport "$GTPS_UDP_PORT" \
    -m comment --comment WYSPS_PROXY_FWD_RETURN \
    -j ACCEPT

  iptables_ensure nat POSTROUTING \
    -o "$pub_if" -p udp -s "$WG_MAIN_IP_ADDR" --sport "$GTPS_UDP_PORT" \
    -m comment --comment WYSPS_PROXY_MASQUERADE \
    -j MASQUERADE

  CHANGED_IPTABLES=1
}

persist_iptables() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y iptables-persistent netfilter-persistent

  netfilter-persistent save
  systemctl enable netfilter-persistent
  systemctl restart netfilter-persistent

  if ! iptables-save | grep -q 'WYSPS_PROXY_'; then
    die "Persist verification failed: no WYSPS_PROXY_ rules found in iptables-save"
  fi
}

rollback_changes() {
  warn "Rolling back partial changes"

  if (( CHANGED_IPTABLES == 1 )); then
    remove_proxy_rules || true
  fi

  if (( CHANGED_WG == 1 )); then
    restore_wg_config || true
  fi

  if (( CHANGED_SSH == 1 )); then
    restore_sshd_config || true
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

verify_mode() {
  require_command wg iptables iptables-save sysctl

  log "Running verification checks"

  local failed=0

  if ! systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    warn "WireGuard interface ${WG_INTERFACE} is not active"
    failed=1
  fi

  if ! wg show "$WG_INTERFACE" >/dev/null 2>&1; then
    warn "wg show ${WG_INTERFACE} failed"
    failed=1
  fi

  if ! ping -c 2 -W 2 "$WG_MAIN_IP_ADDR" >/dev/null 2>&1; then
    warn "Ping to ${WG_MAIN_IP_ADDR} failed"
    failed=1
  fi

  if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
    warn "net.ipv4.ip_forward is not enabled"
    failed=1
  fi

  if ! iptables-save | grep -q 'WYSPS_PROXY_'; then
    warn "No tagged WYSPS_PROXY_ iptables rules found"
    failed=1
  fi

  if ! systemctl is-enabled --quiet netfilter-persistent; then
    warn "netfilter-persistent is not enabled"
    failed=1
  fi

  if (( failed == 1 )); then
    die "Verification failed"
  fi

  log "Verification passed"
}

apply_mode() {
  validate_apply_config
  require_command apt-get iptables iptables-save ip sysctl ss sshd

  check_ubuntu_2404
  ensure_backup_dir
  backup_state
  confirm_firewall_checkpoint

  install_packages
  ensure_admin_user
  harden_ssh
  setup_wireguard
  ensure_ip_forward
  setup_iptables
  persist_iptables

  log "Apply completed successfully"
  log "Backup artifacts stored at ${BACKUP_DIR}"
  log "Gate public WireGuard key: $(< /etc/wireguard/publickey)"
}

main() {
  parse_args "$@"
  load_config
  validate_common_config

  trap 'on_err $LINENO' ERR

  require_root

  case "$MODE" in
    apply) apply_mode ;;
    verify) verify_mode ;;
  esac
}

main "$@"