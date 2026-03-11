#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/.env"

CONFIG_PATH="$DEFAULT_CONFIG_PATH"
OUT_PATH=""
RESTART_TEST="false"
WG_INTERFACE="wg0"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --config /path/.env --out /path/report.md [--restart-test true|false]

Options:
  --config <path>         Path to config .env file (default: ${DEFAULT_CONFIG_PATH})
  --out <path>            Output markdown report path
  --restart-test <bool>   Restart wg/netfilter services for persistence check (default: false)
  -h, --help              Show this help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "Missing value for --config"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --out)
        [[ $# -ge 2 ]] || die "Missing value for --out"
        OUT_PATH="$2"
        shift 2
        ;;
      --restart-test)
        [[ $# -ge 2 ]] || die "Missing value for --restart-test"
        RESTART_TEST="$2"
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
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH"

  # shellcheck disable=SC1090
  source "$CONFIG_PATH"

  GTPS_UDP_PORT="${GTPS_UDP_PORT:-17091}"
  WG_GATE_IP="${WG_GATE_IP:-10.0.0.1/24}"
  WG_MAIN_IP="${WG_MAIN_IP:-10.0.0.2/24}"
  WG_GATE_IP_ADDR="${WG_GATE_IP%/*}"
  WG_MAIN_IP_ADDR="${WG_MAIN_IP%/*}"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must run as root"
}

resolve_out_path() {
  if [[ -z "$OUT_PATH" ]]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    OUT_PATH="${REPO_ROOT}/note/runtime_validation/runs/${ts}/proxy-setup-summary.md"
  fi

  mkdir -p "$(dirname "$OUT_PATH")"
}

cmd_capture() {
  local cmd="$1"
  printf '```bash\n$ %s\n' "$cmd"
  set +e
  eval "$cmd"
  local status=$?
  set -e
  printf '\n(exit=%s)\n```\n\n' "$status"
}

maybe_restart_services() {
  if [[ "$RESTART_TEST" != "true" ]]; then
    printf 'Restart persistence test: skipped (`--restart-test` not enabled).\n\n'
    return
  fi

  printf 'Restart persistence test: running controlled service restart for `wg-quick@%s` and `netfilter-persistent`.\n\n' "$WG_INTERFACE"

  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    systemctl restart "wg-quick@${WG_INTERFACE}" || true
  fi

  if systemctl list-unit-files | grep -q '^netfilter-persistent.service'; then
    systemctl restart netfilter-persistent || true
  fi
}

generate_report() {
  {
    printf '# WysPS Proxy Setup Verification\n\n'
    printf '- Generated at: `%s`\n' "$(date -Iseconds)"
    printf '- Hostname: `%s`\n' "$(hostname)"
    printf '- Config: `%s`\n' "$CONFIG_PATH"
    printf '- Output: `%s`\n\n' "$OUT_PATH"

    printf '## Configuration Snapshot\n\n'
    printf '- `GTPS_UDP_PORT=%s`\n' "$GTPS_UDP_PORT"
    printf '- `WG_GATE_IP=%s`\n' "$WG_GATE_IP"
    printf '- `WG_MAIN_IP=%s`\n\n' "$WG_MAIN_IP"

    printf '## WireGuard State\n\n'
    cmd_capture "wg show ${WG_INTERFACE}"
    cmd_capture "ip addr show ${WG_INTERFACE}"

    printf '## Kernel Routing State\n\n'
    cmd_capture "sysctl net.ipv4.ip_forward"

    printf '## IPTables Tagged Rules\n\n'
    cmd_capture "iptables-save | grep WYSPS_PROXY_"

    printf '## Service Persistence\n\n'
    cmd_capture "systemctl is-enabled wg-quick@${WG_INTERFACE}"
    cmd_capture "systemctl is-active wg-quick@${WG_INTERFACE}"
    cmd_capture "systemctl is-enabled netfilter-persistent"
    cmd_capture "systemctl is-active netfilter-persistent"

    maybe_restart_services

    if [[ "$RESTART_TEST" == "true" ]]; then
      printf '### Post-Restart Checks\n\n'
      cmd_capture "systemctl is-active wg-quick@${WG_INTERFACE}"
      cmd_capture "systemctl is-active netfilter-persistent"
      cmd_capture "iptables-save | grep WYSPS_PROXY_"
    fi

    printf '## Tunnel Reachability\n\n'
    cmd_capture "ping -c 2 -W 2 ${WG_GATE_IP_ADDR}"
    cmd_capture "ping -c 2 -W 2 ${WG_MAIN_IP_ADDR}"

    printf '## Rollback Note\n\n'
    printf '- `proxy-gate.sh` stores rollback artifacts in `/var/backups/wysps-proxy/<timestamp>/` and auto-rollback on failure.\n'
    printf '- Rollback removes only rules tagged with `WYSPS_PROXY_*` and preserves non-related firewall rules.\n'
    printf '- `proxy-main.sh` restores prior `wg0.conf` from backup when handshake/ping validation fails.\n'
  } > "$OUT_PATH"
}

main() {
  parse_args "$@"
  load_config
  resolve_out_path

  require_root

  generate_report
  log "Verification report generated: $OUT_PATH"
}

main "$@"
