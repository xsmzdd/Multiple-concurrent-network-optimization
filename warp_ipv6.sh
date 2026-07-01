#!/usr/bin/env bash
# Cloudflare WARP IPv6-only egress for an IPv4-only VPS.
# IPv4 keeps using the VPS native route; only IPv6 is sent through WARP.

set -Eeuo pipefail

APP_NAME="warp-ipv6"
INSTALL_PATH="/usr/local/sbin/warp-ipv6"
SERVICE_FILE="/etc/systemd/system/warp-ipv6.service"
SYSCTL_FILE="/etc/sysctl.d/99-warp-ipv6.conf"
STATE_DIR="/var/lib/warp-ipv6"
STATE_FILE="${STATE_DIR}/state"
ROLLBACK_UNIT="warp-ipv6-rollback"
ACTION="${1:-install}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 运行：sudo bash $0 ${ACTION}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Newer clients may request ToS confirmation for every CLI invocation.
# Keep all scripted calls non-interactive.
warp_cli() {
  command warp-cli --accept-tos "$@"
}

cancel_rollback() {
  systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

start_rollback() {
  cancel_rollback
  local warp_cli
  warp_cli="$(command -v warp-cli)"
  systemd-run --quiet \
    --unit="${ROLLBACK_UNIT}" \
    --on-active=120s \
    /bin/sh -c "${warp_cli} --accept-tos disconnect >/dev/null 2>&1 || true" >/dev/null
  warn "已启用 120 秒安全回滚；验证成功后会自动取消。"
}

save_ipv6_state() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${STATE_FILE}" ]]; then
    {
      printf 'OLD_ALL=%q\n' "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
      printf 'OLD_DEFAULT=%q\n' "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || echo 0)"
    } > "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
  fi
}

enable_kernel_ipv6() {
  [[ -d /proc/sys/net/ipv6 ]] || die "当前内核未提供 IPv6 支持。"
  save_ipv6_state
  cat > "${SYSCTL_FILE}" <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
SYSCTL
  sysctl -q -p "${SYSCTL_FILE}"
}

check_tun() {
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun >/dev/null 2>&1 || true
  fi
  [[ -c /dev/net/tun ]] || die "缺少 /dev/net/tun；请在 VPS 控制面板启用 TUN/TAP。"
}

install_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends curl ca-certificates gnupg

  # shellcheck disable=SC1091
  source /etc/os-release
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "${codename}" ]] || die "无法识别 Debian/Ubuntu 发行版代号。"

  local key_tmp
  key_tmp="$(mktemp)"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o "${key_tmp}"
  gpg --batch --yes --dearmor \
    --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    "${key_tmp}"
  rm -f "${key_tmp}"

  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
    "${codename}" > /etc/apt/sources.list.d/cloudflare-client.list

  apt-get update
  apt-get install -y cloudflare-warp
}

install_rpm() {
  local pm
  if have dnf; then pm=dnf; else pm=yum; fi

  "${pm}" install -y curl ca-certificates

  # RHEL-compatible 9+ packages may need EPEL dependencies. Best effort only.
  # shellcheck disable=SC1091
  source /etc/os-release
  local major="${VERSION_ID%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ ]] && (( major >= 9 )); then
    "${pm}" install -y epel-release >/dev/null 2>&1 || true
  fi

  rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
  curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
    -o /etc/yum.repos.d/cloudflare-warp.repo
  "${pm}" makecache -y
  "${pm}" install -y cloudflare-warp
}

install_warp_package() {
  if have warp-cli; then
    log "Cloudflare WARP 客户端已安装。"
    return
  fi

  if have apt-get; then
    install_apt
  elif have dnf || have yum; then
    install_rpm
  else
    die "仅支持使用 APT 或 DNF/YUM 的 systemd Linux。"
  fi
}

start_warp_service() {
  systemctl enable warp-svc >/dev/null 2>&1 || true
  systemctl restart warp-svc

  local i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet warp-svc; then
      # 未注册时 warp_cli status 可能返回非零，因此不能用它判断守护进程是否启动。
      sleep 2
      log "warp-svc 已启动。"
      return
    fi
    sleep 1
  done

  systemctl status warp-svc --no-pager -l >&2 || true
  journalctl -u warp-svc --no-pager -n 50 >&2 || true
  die "warp-svc 未能正常启动。"
}

is_registered() {
  local info rc
  set +e
  info="$(warp_cli registration show 2>&1)"
  rc=$?
  set -e

  [[ ${rc} -eq 0 ]] || return 1
  ! grep -Eqi 'RegistrationInfo:[[:space:]]*None|not registered|registration missing|no registration' <<<"${info}"
}

register_warp() {
  if is_registered; then
    log "WARP 客户端已经注册。"
    return
  fi

  log "注册 WARP 客户端……"
  local i
  for i in $(seq 1 5); do
    if warp_cli registration new; then
      break
    fi
    warn "第 ${i} 次注册未成功，稍后重试……"
    sleep 2
  done

  for i in $(seq 1 10); do
    if is_registered; then
      log "WARP 注册成功。"
      return
    fi
    sleep 1
  done

  warp_cli registration show >&2 || true
  journalctl -u warp-svc --no-pager -n 50 >&2 || true
  die "WARP 注册失败。"
}

set_traffic_mode() {
  # Traffic-only mode keeps the system DNS configuration unchanged.
  if warp_cli mode warp >/dev/null 2>&1; then
    return
  fi
  # Fallback for client builds that expose only the combined mode name.
  warp_cli mode warp+doh >/dev/null 2>&1 || die "无法切换到 WARP 流量模式。"
}

split_list() {
  warp_cli tunnel ip list 2>/dev/null \
    || warp_cli tunnel ip show 2>/dev/null \
    || warp_cli tunnel dump 2>/dev/null \
    || true
}

remove_ipv6_exclusion() {
  if ! split_list | grep -Fq '::/0'; then
    return
  fi

  warp_cli tunnel ip remove-range '::/0' >/dev/null 2>&1 \
    || warp_cli tunnel ip remove '::/0' >/dev/null 2>&1 \
    || warp_cli remove-excluded-route '::/0' >/dev/null 2>&1 \
    || die "检测到 ::/0 排除规则，但无法删除。"
}

ensure_ipv4_exclusion() {
  if split_list | grep -Fq '0.0.0.0/0'; then
    return
  fi

  local help_text
  help_text="$(warp_cli tunnel ip --help 2>&1 || true)"

  if grep -q 'add-range' <<<"${help_text}"; then
    warp_cli tunnel ip add-range '0.0.0.0/0'
  elif grep -Eq '(^|[[:space:]])add([[:space:]]|$)' <<<"${help_text}"; then
    warp_cli tunnel ip add '0.0.0.0/0'
  elif warp_cli --help 2>&1 | grep -q 'add-excluded-route'; then
    warp_cli add-excluded-route '0.0.0.0/0'
  else
    die "当前 warp-cli 没有可识别的 IPv4 分流命令。"
  fi
}

configure_ipv6_only() {
  warp_cli disconnect >/dev/null 2>&1 || true
  set_traffic_mode
  remove_ipv6_exclusion
  ensure_ipv4_exclusion
  log "已配置：IPv4 直连，IPv6 通过 WARP。"
}

wait_connected() {
  local i status
  for i in $(seq 1 40); do
    status="$(warp_cli status 2>&1 || true)"
    if grep -Eqi '(^|[^[:alnum:]_])Connected([^[:alnum:]_]|$)' <<<"${status}"; then
      return
    fi
    sleep 1
  done
  warp_cli status >&2 || true
  die "WARP 未能连接。安全回滚仍会执行。"
}

public_ipv4() {
  curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org 2>/dev/null || true
}

public_ipv6() {
  curl -6 -fsS --connect-timeout 8 --max-time 15 https://api64.ipify.org 2>/dev/null || true
}

verify_connection() {
  local ipv4_before="$1" ipv4_after ipv6_after trace
  ipv4_after="$(public_ipv4)"
  ipv6_after="$(public_ipv6)"
  trace="$(curl -6 -fsS --connect-timeout 8 --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"

  [[ -n "${ipv6_after}" ]] || die "IPv6 出口验证失败。安全回滚仍会执行。"
  grep -q '^warp=on$' <<<"${trace}" || die "IPv6 已连通，但未检测到 warp=on。安全回滚仍会执行。"

  if [[ -n "${ipv4_before}" && -n "${ipv4_after}" && "${ipv4_before}" != "${ipv4_after}" ]]; then
    die "IPv4 出口发生变化（${ipv4_before} -> ${ipv4_after}）。安全回滚仍会执行。"
  fi

  cancel_rollback
  log "部署成功。"
  printf 'IPv4 出口：%s\n' "${ipv4_after:-无法检测（应保持 VPS 原出口）}"
  printf 'IPv6 出口：%s\n' "${ipv6_after}"
  printf 'WARP 状态：warp=on\n'
}

install_boot_service() {
  local src
  src="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ "${src}" != "${INSTALL_PATH}" ]]; then
    install -m 0755 "${src}" "${INSTALL_PATH}"
  fi

  cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=Cloudflare WARP IPv6-only egress
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} ensure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable warp-ipv6.service >/dev/null
}

ensure_at_boot() {
  require_root
  have warp-cli || die "未安装 cloudflare-warp。"
  enable_kernel_ipv6
  check_tun
  start_warp_service
  is_registered || die "WARP 尚未注册。"
  configure_ipv6_only
  warp_cli connect >/dev/null
  wait_connected
}

show_status() {
  printf '%s\n' '--- WARP ---'
  warp_cli status 2>&1 || true
  printf '\n%s\n' '--- 出口地址 ---'
  printf 'IPv4: %s\n' "$(public_ipv4)"
  printf 'IPv6: %s\n' "$(public_ipv6)"
  printf '\n%s\n' '--- IPv6 Cloudflare trace ---'
  curl -6 -fsS --connect-timeout 8 --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep -E '^(ip|loc|colo|warp)=' || true
}

remove_ipv4_exclusion() {
  if ! split_list | grep -Fq '0.0.0.0/0'; then
    return
  fi
  warp_cli tunnel ip remove-range '0.0.0.0/0' >/dev/null 2>&1 \
    || warp_cli tunnel ip remove '0.0.0.0/0' >/dev/null 2>&1 \
    || warp_cli remove-excluded-route '0.0.0.0/0' >/dev/null 2>&1 \
    || true
}

remove_deployment() {
  require_root
  cancel_rollback
  systemctl disable --now warp-ipv6.service >/dev/null 2>&1 || true

  if have warp-cli; then
    warp_cli disconnect >/dev/null 2>&1 || true
    remove_ipv4_exclusion
  fi

  rm -f "${SERVICE_FILE}" "${SYSCTL_FILE}"
  systemctl daemon-reload

  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    sysctl -q -w "net.ipv6.conf.all.disable_ipv6=${OLD_ALL:-0}" || true
    sysctl -q -w "net.ipv6.conf.default.disable_ipv6=${OLD_DEFAULT:-0}" || true
  fi
  rm -rf "${STATE_DIR}"

  if [[ "${PURGE:-0}" == "1" ]]; then
    if have apt-get; then
      apt-get remove -y cloudflare-warp || true
    elif have dnf; then
      dnf remove -y cloudflare-warp || true
    elif have yum; then
      yum remove -y cloudflare-warp || true
    fi
  fi

  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "${INSTALL_PATH}" ]]; then
    rm -f "${INSTALL_PATH}"
  else
    (sleep 1; rm -f "${INSTALL_PATH}") >/dev/null 2>&1 &
  fi

  log "已断开 WARP 并移除 IPv6-only 部署。"
}

install_deployment() {
  require_root
  have systemctl || die "需要 systemd。"
  enable_kernel_ipv6
  check_tun
  install_warp_package
  start_warp_service
  register_warp

  local ipv4_before
  ipv4_before="$(public_ipv4)"

  configure_ipv6_only
  start_rollback
  warp_cli connect >/dev/null
  wait_connected
  verify_connection "${ipv4_before}"
  install_boot_service

  printf '\n常用命令：\n'
  printf '  查看状态：%s status\n' "${INSTALL_PATH}"
  printf '  重新连接：%s ensure\n' "${INSTALL_PATH}"
  printf '  移除配置：%s remove\n' "${INSTALL_PATH}"
  printf '  连同软件卸载：PURGE=1 %s remove\n' "${INSTALL_PATH}"
}

case "${ACTION}" in
  install) install_deployment ;;
  ensure|reconnect) ensure_at_boot ;;
  status) show_status ;;
  remove|uninstall) remove_deployment ;;
  *)
    cat >&2 <<EOF_USAGE
用法：$0 [install|ensure|status|remove]
  install  安装并部署（默认）
  ensure   重新应用 IPv6-only 分流并连接
  status   查看 WARP、IPv4 和 IPv6 状态
  remove   断开并移除部署；PURGE=1 时同时卸载客户端
EOF_USAGE
    exit 2
    ;;
esac
