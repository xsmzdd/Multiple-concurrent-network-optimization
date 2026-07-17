#!/usr/bin/env bash
# ==============================================================================
# Cloudflare WARP 双栈出口管理脚本
#
# 功能：
#   1. 为仅有原生 IPv6 的 VPS 附加 WARP IPv4 出口
#   2. 为仅有原生 IPv4 的 VPS 附加 WARP IPv6 出口
#   3. 扫描 Cloudflare WARP 接入端点，显示延迟最低的 10 个供用户选择
#   4. 使用 systemd timer 每 10 分钟自动重新优选最低延迟端点
#   5. 安装、状态检查、开机恢复、失败回滚和完整卸载
#
# 说明：
#   WARP 客户端不能直接指定最终公网出口 IP。本脚本优选的是 Cloudflare
#   隧道接入端点（Endpoint）；最终公网 IPv4/IPv6 出口由 Cloudflare 分配。
#
# 支持：使用 systemd 且包管理器为 APT、DNF 或 YUM 的 Linux。
# 建议：Debian 12/13、Ubuntu 22.04/24.04、RHEL/Rocky/AlmaLinux 9/10。
# ==============================================================================

set -Eeuo pipefail
umask 022
export LC_ALL=C

# ------------------------------- 基本配置 ------------------------------------
APP_NAME="warp-egress"
APP_TITLE="Cloudflare WARP 双栈出口管理"
SCRIPT_VERSION="2.0.0"

INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="/run/${APP_NAME}.lock"

BOOT_SERVICE="/etc/systemd/system/${APP_NAME}.service"
AUTO_SERVICE="/etc/systemd/system/${APP_NAME}-auto-switch.service"
AUTO_TIMER="/etc/systemd/system/${APP_NAME}-auto-switch.timer"
SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"
ROLLBACK_UNIT="${APP_NAME}-rollback"

# 端点扫描并发数和每个地址的 ICMP 测试次数。
SCAN_PARALLEL="${SCAN_PARALLEL:-48}"
PING_COUNT="${PING_COUNT:-3}"
SELECT_TIMEOUT="${SELECT_TIMEOUT:-30}"

# ANSI 颜色。输出不是终端时自动禁用，避免 systemd 日志出现转义字符。
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[1;31m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'
    C_MAGENTA='\033[1;35m'
    C_CYAN='\033[1;36m'
    C_WHITE='\033[1;37m'
    C_DIM='\033[2m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
    C_MAGENTA='' C_CYAN='' C_WHITE='' C_DIM=''
fi

# ------------------------------- 状态变量 ------------------------------------
# 下列变量会写入 STATE_FILE。STATE_FILE 仅允许 root 读取和修改。
DEPLOY_MODE=""                 # ipv4：附加 IPv4；ipv6：附加 IPv6
ENDPOINT=""                    # 当前优选的 WARP 接入端点 IP
ENDPOINT_FAMILY=""             # 4 或 6，表示连接接入端点使用的原生网络族
TUNNEL_PROTOCOL="MASQUE"       # MASQUE 或 WireGuard
ENDPOINT_PORT="443"
AUTO_SWITCH="0"
LAST_LATENCY=""
LAST_SWITCH_TIME=""

# 初次部署前的系统状态，用于卸载时恢复。
OLD_ALL_IPV6="0"
OLD_DEFAULT_IPV6="0"
ORIGINAL_IPV4_EXCLUDED="-1"
ORIGINAL_IPV6_EXCLUDED="-1"
STATE_INITIALIZED="0"

# -------------------------------- 日志函数 ------------------------------------
log()  { printf '%b[✓]%b %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
info() { printf '%b[i]%b %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
warn() { printf '%b[!]%b %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%b[✗]%b %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 权限运行本脚本。"
}

require_systemd() {
    have systemctl || die "当前系统未检测到 systemd。"
    [[ -d /run/systemd/system ]] || die "systemd 当前未作为 init 系统运行。"
}

# 所有会修改 WARP 状态的操作共用同一把文件锁，防止菜单、开机服务和
# 10 分钟定时任务同时执行而互相覆盖配置。
acquire_operation_lock() {
    local wait_seconds="${1:-180}"
    have flock || die "缺少 flock 命令，请安装 util-linux。"
    exec 9>"${LOCK_FILE}"
    flock -w "${wait_seconds}" 9 || die "另一个 WARP 管理任务仍在运行，请稍后重试。"
}

pause_screen() {
    [[ -t 0 ]] || return 0
    printf '\n%b按 Enter 返回主菜单...%b' "${C_DIM}" "${C_RESET}"
    read -r _ || true
}

# ------------------------------- 状态管理 ------------------------------------
load_state() {
    # 每次加载前先重置默认值，避免旧 shell 变量污染。
    DEPLOY_MODE=""
    ENDPOINT=""
    ENDPOINT_FAMILY=""
    TUNNEL_PROTOCOL="MASQUE"
    ENDPOINT_PORT="443"
    AUTO_SWITCH="0"
    LAST_LATENCY=""
    LAST_SWITCH_TIME=""
    OLD_ALL_IPV6="0"
    OLD_DEFAULT_IPV6="0"
    ORIGINAL_IPV4_EXCLUDED="-1"
    ORIGINAL_IPV6_EXCLUDED="-1"
    STATE_INITIALIZED="0"

    if [[ -f "${STATE_FILE}" ]]; then
        # STATE_FILE 由本脚本以 0600 权限创建，内容使用 printf %q 转义。
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
    fi
}

save_state() {
    mkdir -p "${STATE_DIR}"
    local tmp
    tmp="$(mktemp "${STATE_DIR}/state.XXXXXX")"

    {
        printf 'DEPLOY_MODE=%q\n' "${DEPLOY_MODE}"
        printf 'ENDPOINT=%q\n' "${ENDPOINT}"
        printf 'ENDPOINT_FAMILY=%q\n' "${ENDPOINT_FAMILY}"
        printf 'TUNNEL_PROTOCOL=%q\n' "${TUNNEL_PROTOCOL}"
        printf 'ENDPOINT_PORT=%q\n' "${ENDPOINT_PORT}"
        printf 'AUTO_SWITCH=%q\n' "${AUTO_SWITCH}"
        printf 'LAST_LATENCY=%q\n' "${LAST_LATENCY}"
        printf 'LAST_SWITCH_TIME=%q\n' "${LAST_SWITCH_TIME}"
        printf 'OLD_ALL_IPV6=%q\n' "${OLD_ALL_IPV6}"
        printf 'OLD_DEFAULT_IPV6=%q\n' "${OLD_DEFAULT_IPV6}"
        printf 'ORIGINAL_IPV4_EXCLUDED=%q\n' "${ORIGINAL_IPV4_EXCLUDED}"
        printf 'ORIGINAL_IPV6_EXCLUDED=%q\n' "${ORIGINAL_IPV6_EXCLUDED}"
        printf 'STATE_INITIALIZED=%q\n' "${STATE_INITIALIZED}"
    } > "${tmp}"

    chmod 600 "${tmp}"
    mv -f "${tmp}" "${STATE_FILE}"
}

initialize_system_state() {
    load_state
    if [[ "${STATE_INITIALIZED}" == "1" ]]; then
        return 0
    fi

    mkdir -p "${STATE_DIR}"
    OLD_ALL_IPV6="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
    OLD_DEFAULT_IPV6="$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || echo 0)"
    STATE_INITIALIZED="1"
    save_state
}

# ----------------------------- WARP CLI 包装 ---------------------------------
# 新版客户端可能要求每次命令确认服务条款；--accept-tos 保证脚本非交互执行。
warp_cli() {
    command warp-cli --accept-tos "$@"
}

warp_status_text() {
    warp_cli status 2>&1 || true
}

is_warp_connected() {
    warp_status_text | grep -Eqi '(^|[^[:alnum:]_])Connected([^[:alnum:]_]|$)'
}

is_registered() {
    local output rc
    set +e
    output="$(warp_cli registration show 2>&1)"
    rc=$?
    set -e

    [[ ${rc} -eq 0 ]] || return 1
    ! grep -Eqi 'RegistrationInfo:[[:space:]]*None|not registered|registration missing|no registration' <<<"${output}"
}

register_warp() {
    if is_registered; then
        log "WARP 客户端已经注册。"
        return 0
    fi

    info "正在注册 WARP 客户端..."
    local i
    for i in $(seq 1 5); do
        if warp_cli registration new >/dev/null 2>&1; then
            break
        fi
        warn "第 ${i} 次注册失败，2 秒后重试。"
        sleep 2
    done

    for i in $(seq 1 10); do
        if is_registered; then
            log "WARP 注册成功。"
            return 0
        fi
        sleep 1
    done

    warp_cli registration show >&2 || true
    journalctl -u warp-svc --no-pager -n 50 >&2 || true
    die "WARP 注册失败。"
}

set_traffic_mode() {
    # 新版 Cloudflare One Client 将纯流量模式称为 tunnelonly；不同版本的
    # CLI 拼写可能略有差异，因此依次尝试常见形式。
    local mode
    for mode in tunnelonly tunnel_only tunnel-only; do
        if warp_cli mode "${mode}" >/dev/null 2>&1; then
            return 0
        fi
    done

    # 旧版消费级 WARP 客户端中，warp 通常表示隧道流量模式。
    if warp_cli mode warp >/dev/null 2>&1; then
        return 0
    fi

    # 最后兼容只提供 warp+doh 的旧版本；该模式会同时管理 DNS。
    warn "当前客户端不支持可识别的纯流量模式，尝试兼容模式 warp+doh。"
    warp_cli mode warp+doh >/dev/null 2>&1 || die "无法切换到 WARP 流量模式。"
}

set_tunnel_protocol() {
    # 优先使用 MASQUE；它是当前客户端的默认协议，端点使用 UDP/TCP 443。
    if warp_cli tunnel protocol set MASQUE >/dev/null 2>&1 \
        || warp_cli tunnel protocol set masque >/dev/null 2>&1; then
        TUNNEL_PROTOCOL="MASQUE"
        ENDPOINT_PORT="443"
        return 0
    fi

    # 对不支持 MASQUE 的旧客户端回退到 WireGuard。
    warn "当前客户端无法设置 MASQUE，回退到 WireGuard。"
    if warp_cli tunnel protocol set WireGuard >/dev/null 2>&1 \
        || warp_cli tunnel protocol set wireguard >/dev/null 2>&1; then
        TUNNEL_PROTOCOL="WireGuard"
        ENDPOINT_PORT="2408"
        return 0
    fi

    # 很旧的客户端没有协议子命令，通常默认使用 WireGuard。
    warn "当前 warp-cli 没有协议设置命令，将按 WireGuard 兼容模式处理。"
    TUNNEL_PROTOCOL="WireGuard"
    ENDPOINT_PORT="2408"
}

set_custom_endpoint() {
    local ip="$1" port="$2" formatted
    if [[ "${ip}" == *:* ]]; then
        formatted="[${ip}]:${port}"
    else
        formatted="${ip}:${port}"
    fi

    # 新版命令。
    if warp_cli tunnel endpoint set "${formatted}" >/dev/null 2>&1; then
        return 0
    fi

    # 某些版本接受未加方括号的 IPv6 地址。
    if [[ "${ip}" == *:* ]] && warp_cli tunnel endpoint set "${ip}:${port}" >/dev/null 2>&1; then
        return 0
    fi

    # 旧版兼容命令。
    warp_cli set-custom-endpoint "${formatted}" >/dev/null 2>&1 \
        || warp_cli set-custom-endpoint "${ip}:${port}" >/dev/null 2>&1 \
        || return 1
}

reset_custom_endpoint() {
    warp_cli tunnel endpoint reset >/dev/null 2>&1 \
        || warp_cli clear-custom-endpoint >/dev/null 2>&1 \
        || true
}

# --------------------------- Split Tunnel 管理 -------------------------------
split_list() {
    warp_cli tunnel ip list 2>/dev/null \
        || warp_cli tunnel ip show 2>/dev/null \
        || warp_cli tunnel dump 2>/dev/null \
        || true
}

range_is_excluded() {
    local cidr="$1"
    split_list | grep -Fq "${cidr}"
}

add_excluded_range() {
    local cidr="$1"
    range_is_excluded "${cidr}" && return 0

    local help_text
    help_text="$(warp_cli tunnel ip --help 2>&1 || true)"

    if grep -q 'add-range' <<<"${help_text}"; then
        warp_cli tunnel ip add-range "${cidr}" >/dev/null
    elif grep -Eq '(^|[[:space:]])add([[:space:]]|$)' <<<"${help_text}"; then
        warp_cli tunnel ip add "${cidr}" >/dev/null
    elif warp_cli --help 2>&1 | grep -q 'add-excluded-route'; then
        warp_cli add-excluded-route "${cidr}" >/dev/null
    else
        die "当前 warp-cli 没有可识别的分流添加命令。"
    fi
}

remove_excluded_range() {
    local cidr="$1"
    range_is_excluded "${cidr}" || return 0

    warp_cli tunnel ip remove-range "${cidr}" >/dev/null 2>&1 \
        || warp_cli tunnel ip remove "${cidr}" >/dev/null 2>&1 \
        || warp_cli remove-excluded-route "${cidr}" >/dev/null 2>&1 \
        || die "检测到 ${cidr} 排除规则，但无法删除。"
}

capture_original_split_state() {
    load_state
    if [[ "${ORIGINAL_IPV4_EXCLUDED}" == "-1" ]]; then
        if range_is_excluded '0.0.0.0/0'; then
            ORIGINAL_IPV4_EXCLUDED="1"
        else
            ORIGINAL_IPV4_EXCLUDED="0"
        fi
    fi

    if [[ "${ORIGINAL_IPV6_EXCLUDED}" == "-1" ]]; then
        if range_is_excluded '::/0'; then
            ORIGINAL_IPV6_EXCLUDED="1"
        else
            ORIGINAL_IPV6_EXCLUDED="0"
        fi
    fi
    save_state
}

configure_split_tunnel() {
    local target="$1"
    warp_cli disconnect >/dev/null 2>&1 || true
    set_traffic_mode

    case "${target}" in
        ipv4)
            # IPv4 进入 WARP；IPv6 保持 VPS 原生出口。
            remove_excluded_range '0.0.0.0/0'
            add_excluded_range '::/0'
            log "分流已配置：IPv4 通过 WARP，IPv6 保持原生出口。"
            ;;
        ipv6)
            # IPv6 进入 WARP；IPv4 保持 VPS 原生出口。
            add_excluded_range '0.0.0.0/0'
            remove_excluded_range '::/0'
            log "分流已配置：IPv4 保持原生出口，IPv6 通过 WARP。"
            ;;
        *)
            die "未知部署模式：${target}"
            ;;
    esac
}

# 卸载阶段使用“不退出脚本”的分流恢复函数。即使某个旧版 warp-cli 命令
# 不兼容，也应继续完成软件包和 systemd 单元的清理。
add_excluded_range_best_effort() {
    local cidr="$1" help_text
    range_is_excluded "${cidr}" && return 0
    help_text="$(warp_cli tunnel ip --help 2>&1 || true)"

    if grep -q 'add-range' <<<"${help_text}"; then
        warp_cli tunnel ip add-range "${cidr}" >/dev/null 2>&1 || true
    elif grep -Eq '(^|[[:space:]])add([[:space:]]|$)' <<<"${help_text}"; then
        warp_cli tunnel ip add "${cidr}" >/dev/null 2>&1 || true
    else
        warp_cli add-excluded-route "${cidr}" >/dev/null 2>&1 || true
    fi
}

remove_excluded_range_best_effort() {
    local cidr="$1"
    range_is_excluded "${cidr}" || return 0
    warp_cli tunnel ip remove-range "${cidr}" >/dev/null 2>&1 \
        || warp_cli tunnel ip remove "${cidr}" >/dev/null 2>&1 \
        || warp_cli remove-excluded-route "${cidr}" >/dev/null 2>&1 \
        || true
}

restore_original_split_state() {
    [[ "${ORIGINAL_IPV4_EXCLUDED}" != "-1" ]] || return 0
    [[ "${ORIGINAL_IPV6_EXCLUDED}" != "-1" ]] || return 0

    if [[ "${ORIGINAL_IPV4_EXCLUDED}" == "1" ]]; then
        add_excluded_range_best_effort '0.0.0.0/0'
    else
        remove_excluded_range_best_effort '0.0.0.0/0'
    fi

    if [[ "${ORIGINAL_IPV6_EXCLUDED}" == "1" ]]; then
        add_excluded_range_best_effort '::/0'
    else
        remove_excluded_range_best_effort '::/0'
    fi
}

# ------------------------------ 系统环境安装 ---------------------------------
enable_kernel_ipv6() {
    [[ -d /proc/sys/net/ipv6 ]] || die "当前内核未提供 IPv6 支持。"

    cat > "${SYSCTL_FILE}" <<'SYSCTL'
# WARP 虚拟隧道需要内核 IPv6 栈可用，即使 VPS 原生网络只有 IPv4。
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
    apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg iputils-ping util-linux

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
    if have dnf; then pm="dnf"; else pm="yum"; fi

    "${pm}" install -y curl ca-certificates iputils util-linux

    # RHEL 9+ 可能需要 EPEL 中的桌面相关依赖。失败不影响继续尝试安装。
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
        # 即使客户端已存在，也补齐本脚本所需工具。
        if have apt-get; then
            apt-get update >/dev/null
            apt-get install -y --no-install-recommends curl iputils-ping util-linux >/dev/null
        elif have dnf; then
            dnf install -y curl iputils util-linux >/dev/null
        elif have yum; then
            yum install -y curl iputils util-linux >/dev/null
        fi
        return 0
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
            sleep 2
            log "warp-svc 已启动。"
            return 0
        fi
        sleep 1
    done

    systemctl status warp-svc --no-pager -l >&2 || true
    journalctl -u warp-svc --no-pager -n 50 >&2 || true
    die "warp-svc 未能正常启动。"
}

uninstall_warp_package() {
    if have apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y cloudflare-warp || true
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        apt-get update >/dev/null 2>&1 || true
    elif have dnf; then
        dnf remove -y cloudflare-warp || true
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    elif have yum; then
        yum remove -y cloudflare-warp || true
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    fi
}

# ------------------------------ 网络检测函数 ---------------------------------
public_ipv4() {
    curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org 2>/dev/null || true
}

public_ipv6() {
    curl -6 -fsS --connect-timeout 8 --max-time 15 https://api64.ipify.org 2>/dev/null || true
}

cloudflare_trace() {
    local family="$1"
    curl "-${family}" -fsS --connect-timeout 8 --max-time 15 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true
}

has_native_family() {
    local family="$1"
    if [[ "${family}" == "4" ]]; then
        [[ -n "$(public_ipv4)" ]]
    else
        [[ -n "$(public_ipv6)" ]]
    fi
}

choose_endpoint_family() {
    local target="$1"

    # 附加 IPv4 时优先用 VPS 原生 IPv6 建立隧道；附加 IPv6 时反之。
    if [[ "${target}" == "ipv4" ]]; then
        if has_native_family 6; then
            printf '6\n'
        elif has_native_family 4; then
            warn "未检测到原生 IPv6，将改用 IPv4 接入端点。"
            printf '4\n'
        else
            die "未检测到可用的原生 IPv4 或 IPv6 网络。"
        fi
    else
        if has_native_family 4; then
            printf '4\n'
        elif has_native_family 6; then
            warn "未检测到原生 IPv4，将改用 IPv6 接入端点。"
            printf '6\n'
        else
            die "未检测到可用的原生 IPv4 或 IPv6 网络。"
        fi
    fi
}

wait_connected() {
    local i status
    for i in $(seq 1 45); do
        status="$(warp_status_text)"
        if grep -Eqi '(^|[^[:alnum:]_])Connected([^[:alnum:]_]|$)' <<<"${status}"; then
            return 0
        fi
        sleep 1
    done

    warp_cli status >&2 || true
    return 1
}

# ------------------------------ 端点延迟扫描 ---------------------------------
# 根据 Cloudflare 官方公布的 WARP ingress 网段生成候选端点。
# MASQUE：IPv4 162.159.197.0/24；IPv6 2606:4700:102::/48；默认端口 443。
# WireGuard：IPv4 162.159.193.0/24；IPv6 2606:4700:100::/48；默认端口 2408。
generate_candidates() {
    local family="$1" protocol="$2" i hex prefix embedded_prefix

    if [[ "${protocol,,}" == "masque" ]]; then
        if [[ "${family}" == "4" ]]; then
            for i in $(seq 1 254); do
                printf '162.159.197.%d\n' "${i}"
            done
        else
            prefix="2606:4700:102"
            embedded_prefix="c5"  # 162.159.197.x 中 197 的十六进制为 c5。
            # 同时测试低位地址和 IPv4 嵌入式地址，提高不同客户端版本下的命中率。
            for i in $(seq 1 127); do
                printf '%s::%x\n' "${prefix}" "${i}"
            done
            for i in $(seq 128 254); do
                printf -v hex '%02x' "${i}"
                printf '%s::a29f:%s%s\n' "${prefix}" "${embedded_prefix}" "${hex}"
            done
        fi
    else
        if [[ "${family}" == "4" ]]; then
            for i in $(seq 1 254); do
                printf '162.159.193.%d\n' "${i}"
            done
        else
            prefix="2606:4700:100"
            embedded_prefix="c1"  # 162.159.193.x 中 193 的十六进制为 c1。
            for i in $(seq 1 127); do
                printf '%s::%x\n' "${prefix}" "${i}"
            done
            for i in $(seq 128 254); do
                printf -v hex '%02x' "${i}"
                printf '%s::a29f:%s%s\n' "${prefix}" "${embedded_prefix}" "${hex}"
            done
        fi
    fi
}

# 对单个端点执行多次 ping，输出“IP<TAB>平均延迟”。
# 此函数会由并行子 shell 调用，因此必须保持无外部状态依赖。
probe_endpoint() {
    local family="$1" ip="$2" output latency

    if [[ "${family}" == "4" ]]; then
        output="$(timeout 5 ping -4 -n -c "${PING_COUNT}" -W 1 "${ip}" 2>/dev/null || true)"
    else
        output="$(timeout 5 ping -6 -n -c "${PING_COUNT}" -W 1 "${ip}" 2>/dev/null || true)"
    fi

    # 兼容 iputils 的 rtt 和部分系统的 round-trip 输出。
    latency="$(awk -F'/' '/^(rtt|round-trip) / {print $5; exit}' <<<"${output}")"
    if [[ "${latency}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\t%s\n' "${ip}" "${latency}"
    fi
}

export -f probe_endpoint
export PING_COUNT

scan_best_endpoints() {
    local family="$1" protocol="$2" tmp sorted
    tmp="$(mktemp)"
    sorted="$(mktemp)"

    info "正在扫描 WARP ${protocol} IPv${family} 接入端点，请稍候..." >&2

    # xargs 并行执行，避免顺序扫描 254 个地址耗时过长。
    generate_candidates "${family}" "${protocol}" \
        | xargs -r -n 1 -P "${SCAN_PARALLEL}" \
            bash -c 'probe_endpoint "$1" "$2"' _ "${family}" \
        > "${tmp}"

    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}" "${sorted}"
        return 1
    fi

    # 先完整排序到临时文件，再读取前 10 个，避免 pipefail 下 sort 因
    # head 提前关闭管道而产生 SIGPIPE 非零退出码。
    sort -t $'\t' -k2,2n "${tmp}" > "${sorted}"
    head -n 10 "${sorted}"
    rm -f "${tmp}" "${sorted}"
}

fallback_endpoint() {
    local family="$1" protocol="$2"
    if [[ "${protocol,,}" == "masque" ]]; then
        [[ "${family}" == "4" ]] && printf '162.159.197.3\n' || printf '2606:4700:102::3\n'
    else
        [[ "${family}" == "4" ]] && printf '162.159.193.1\n' || printf '2606:4700:100::1\n'
    fi
}

select_endpoint_interactively() {
    local family="$1" protocol="$2"
    local -a results=()
    local line i choice selected_ip selected_latency

    mapfile -t results < <(scan_best_endpoints "${family}" "${protocol}" || true)

    if (( ${#results[@]} == 0 )); then
        selected_ip="$(fallback_endpoint "${family}" "${protocol}")"
        selected_latency="未知"
        warn "没有端点响应 ICMP，使用官方接入网段中的保守默认地址：${selected_ip}"
        printf '%s\t%s\n' "${selected_ip}" "${selected_latency}"
        return 0
    fi

    # 菜单内容写入 stderr，保证函数在命令替换中调用时仍能实时显示；
    # stdout 只保留最终选择结果，便于调用者可靠解析。
    {
        printf '\n%b┌──────────────────────────────────────────────────────┐%b\n' "${C_BLUE}" "${C_RESET}"
        printf '%b│%b  延迟最低的 WARP 接入端点                           %b│%b\n' "${C_BLUE}" "${C_WHITE}" "${C_BLUE}" "${C_RESET}"
        printf '%b├────┬───────────────────────────────────┬─────────────┤%b\n' "${C_BLUE}" "${C_RESET}"
        printf '%b│%b 序号 %b│%b IP 地址                           %b│%b 平均延迟    %b│%b\n' \
            "${C_BLUE}" "${C_WHITE}" "${C_BLUE}" "${C_WHITE}" \
            "${C_BLUE}" "${C_WHITE}" "${C_BLUE}" "${C_RESET}"
        printf '%b├────┼───────────────────────────────────┼─────────────┤%b\n' "${C_BLUE}" "${C_RESET}"

        for i in "${!results[@]}"; do
            IFS=$'\t' read -r selected_ip selected_latency <<<"${results[$i]}"
            printf '%b│%b %2d %b│%b %-33s %b│%b %8s ms %b│%b\n' \
                "${C_BLUE}" "${C_CYAN}" "$((i + 1))" "${C_BLUE}" "${C_WHITE}" \
                "${selected_ip}" "${C_BLUE}" "${C_GREEN}" "${selected_latency}" \
                "${C_BLUE}" "${C_RESET}"
        done
        printf '%b└────┴───────────────────────────────────┴─────────────┘%b\n' "${C_BLUE}" "${C_RESET}"
    } >&2

    choice="1"
    if [[ -t 0 ]]; then
        printf '%b请选择端点 [1-%d]，%d 秒后默认选择 1：%b' \
            "${C_YELLOW}" "${#results[@]}" "${SELECT_TIMEOUT}" "${C_RESET}" >&2
        if ! read -r -t "${SELECT_TIMEOUT}" choice; then
            printf '\n' >&2
            choice="1"
            info "选择超时，已自动使用延迟最低的端点。" >&2
        fi
    fi

    if [[ ! "${choice}" =~ ^[0-9]+$ ]] \
        || (( choice < 1 || choice > ${#results[@]} )); then
        warn "输入无效，已自动使用延迟最低的端点。"
        choice="1"
    fi

    line="${results[$((choice - 1))]}"
    printf '%s\n' "${line}"
}

select_best_endpoint_noninteractive() {
    local family="$1" protocol="$2"
    local result
    result="$(scan_best_endpoints "${family}" "${protocol}" | head -n 1 || true)"

    if [[ -z "${result}" ]]; then
        printf '%s\t%s\n' "$(fallback_endpoint "${family}" "${protocol}")" "未知"
    else
        printf '%s\n' "${result}"
    fi
}

# ----------------------------- 连接验证与回滚 --------------------------------
cancel_rollback() {
    systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

start_rollback() {
    cancel_rollback
    local cli_path
    cli_path="$(command -v warp-cli)"

    systemd-run --quiet \
        --unit="${ROLLBACK_UNIT}" \
        --on-active=120s \
        /bin/sh -c "${cli_path} --accept-tos disconnect >/dev/null 2>&1 || true" \
        >/dev/null

    warn "已启用 120 秒安全回滚；验证成功后会自动取消。"
}

verify_target_family() {
    local target="$1" native_before="${2:-}" target_ip native_after trace

    if [[ "${target}" == "ipv4" ]]; then
        target_ip="$(public_ipv4)"
        native_after="$(public_ipv6)"
        trace="$(cloudflare_trace 4)"

        [[ -n "${target_ip}" ]] || return 1
        grep -q '^warp=on$' <<<"${trace}" || return 1
        if [[ -n "${native_before}" && -n "${native_after}" && "${native_before}" != "${native_after}" ]]; then
            warn "原生 IPv6 出口发生变化：${native_before} -> ${native_after}"
            return 1
        fi
    else
        target_ip="$(public_ipv6)"
        native_after="$(public_ipv4)"
        trace="$(cloudflare_trace 6)"

        [[ -n "${target_ip}" ]] || return 1
        grep -q '^warp=on$' <<<"${trace}" || return 1
        if [[ -n "${native_before}" && -n "${native_after}" && "${native_before}" != "${native_after}" ]]; then
            warn "原生 IPv4 出口发生变化：${native_before} -> ${native_after}"
            return 1
        fi
    fi
    return 0
}

connect_and_verify() {
    local target="$1" native_before="$2"

    start_rollback
    warp_cli connect >/dev/null 2>&1 || true

    if ! wait_connected; then
        die "WARP 未能连接；安全回滚仍会执行。"
    fi

    if ! verify_target_family "${target}" "${native_before}"; then
        die "WARP 出口验证失败；安全回滚仍会执行。"
    fi

    cancel_rollback
    log "WARP 连接及分流验证成功。"
}

# ----------------------------- systemd 服务 ---------------------------------
install_self() {
    local src
    src="$(readlink -f "${BASH_SOURCE[0]}")"
    if [[ "${src}" != "${INSTALL_PATH}" ]]; then
        install -m 0755 "${src}" "${INSTALL_PATH}"
    else
        chmod 0755 "${INSTALL_PATH}"
    fi
}

install_boot_service() {
    install_self

    cat > "${BOOT_SERVICE}" <<EOF
[Unit]
Description=Cloudflare WARP selected-family egress
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} ensure
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${APP_NAME}.service" >/dev/null
    log "已创建 WARP 开机恢复服务。"
}

install_auto_switch_units() {
    install_self

    cat > "${AUTO_SERVICE}" <<EOF
[Unit]
Description=Select the lowest-latency Cloudflare WARP endpoint
After=network-online.target warp-svc.service ${APP_NAME}.service
Wants=network-online.target
Requires=warp-svc.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} auto-switch
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=180
EOF

    cat > "${AUTO_TIMER}" <<'EOF'
[Unit]
Description=Run WARP endpoint latency selection every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=20s
Persistent=true
Unit=warp-egress-auto-switch.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
}

# ------------------------------- 安装流程 ------------------------------------
install_deployment() {
    local target="$1" native_before endpoint_result selected_ip selected_latency
    local lock_acquired="0"

    require_root
    require_systemd
    # util-linux/flock 在首次安装依赖前可能尚不存在；此时先安装依赖，随后加锁。
    if have flock; then
        acquire_operation_lock
        lock_acquired="1"
    fi
    initialize_system_state
    enable_kernel_ipv6
    check_tun
    install_warp_package
    if [[ "${lock_acquired}" == "0" ]]; then
        acquire_operation_lock
    fi
    start_warp_service
    register_warp
    capture_original_split_state

    set_tunnel_protocol
    ENDPOINT_FAMILY="$(choose_endpoint_family "${target}")"

    if [[ "${target}" == "ipv4" ]]; then
        native_before="$(public_ipv6)"
    else
        native_before="$(public_ipv4)"
    fi

    endpoint_result="$(select_endpoint_interactively "${ENDPOINT_FAMILY}" "${TUNNEL_PROTOCOL}")"
    IFS=$'\t' read -r selected_ip selected_latency <<<"${endpoint_result##*$'\n'}"
    [[ -n "${selected_ip}" ]] || die "没有得到可用的 WARP 接入端点。"

    info "正在应用接入端点：${selected_ip}:${ENDPOINT_PORT}"
    set_custom_endpoint "${selected_ip}" "${ENDPOINT_PORT}" \
        || die "当前 warp-cli 无法设置自定义接入端点。"

    configure_split_tunnel "${target}"
    connect_and_verify "${target}" "${native_before}"

    DEPLOY_MODE="${target}"
    ENDPOINT="${selected_ip}"
    LAST_LATENCY="${selected_latency}"
    LAST_SWITCH_TIME="$(date '+%F %T %z')"
    save_state
    install_boot_service

    printf '\n%b════════════════ 部署完成 ════════════════%b\n' "${C_GREEN}" "${C_RESET}"
    printf '部署模式：%s\n' "$([[ "${target}" == "ipv4" ]] && echo 'WARP-IPv4' || echo 'WARP-IPv6')"
    printf '接入端点：%s:%s\n' "${ENDPOINT}" "${ENDPOINT_PORT}"
    printf '测试延迟：%s%s\n' "${LAST_LATENCY}" "$([[ "${LAST_LATENCY}" == "未知" ]] && echo '' || echo ' ms')"
    printf 'IPv4 出口：%s\n' "$(public_ipv4)"
    printf 'IPv6 出口：%s\n' "$(public_ipv6)"
    printf '%b════════════════════════════════════════%b\n' "${C_GREEN}" "${C_RESET}"
}

ensure_deployment() {
    require_root
    require_systemd
    acquire_operation_lock
    load_state

    [[ "${DEPLOY_MODE}" == "ipv4" || "${DEPLOY_MODE}" == "ipv6" ]] \
        || die "没有已保存的 WARP 部署模式。"
    have warp-cli || die "未安装 cloudflare-warp。"

    enable_kernel_ipv6
    check_tun
    start_warp_service
    is_registered || die "WARP 尚未注册。"

    set_traffic_mode
    if [[ -n "${ENDPOINT}" ]]; then
        set_custom_endpoint "${ENDPOINT}" "${ENDPOINT_PORT}" \
            || warn "恢复自定义接入端点失败，将由 WARP 自动选择端点。"
    fi

    configure_split_tunnel "${DEPLOY_MODE}"
    warp_cli connect >/dev/null 2>&1 || true
    wait_connected || die "开机恢复 WARP 连接失败。"
}

# --------------------------- 自动延迟切换功能 --------------------------------
enable_auto_switch() {
    require_root
    require_systemd
    acquire_operation_lock
    load_state

    [[ "${DEPLOY_MODE}" == "ipv4" || "${DEPLOY_MODE}" == "ipv6" ]] \
        || die "请先安装 WARP-IPv4 或 WARP-IPv6。"

    install_auto_switch_units
    AUTO_SWITCH="1"
    save_state
    if ! systemctl enable --now "${APP_NAME}-auto-switch.timer" >/dev/null; then
        AUTO_SWITCH="0"
        save_state
        die "systemd 自动切换定时器启动失败。"
    fi

    log "延迟自动切换已开启，每 10 分钟检查一次。"
    systemctl list-timers "${APP_NAME}-auto-switch.timer" --no-pager || true
}

disable_auto_switch() {
    require_root
    require_systemd
    acquire_operation_lock
    load_state

    systemctl disable --now "${APP_NAME}-auto-switch.timer" >/dev/null 2>&1 || true
    rm -f "${AUTO_SERVICE}" "${AUTO_TIMER}"
    systemctl daemon-reload
    systemctl reset-failed "${APP_NAME}-auto-switch.service" \
        "${APP_NAME}-auto-switch.timer" >/dev/null 2>&1 || true

    AUTO_SWITCH="0"
    [[ -d "${STATE_DIR}" ]] && save_state
    log "延迟自动切换已关闭。"
}

auto_switch_endpoint() {
    require_root
    require_systemd

    # 防止手动操作和 timer 同时修改 WARP 设置。
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        warn "另一个 WARP 管理任务正在运行，本次自动检查跳过。"
        return 0
    fi

    load_state
    [[ "${AUTO_SWITCH}" == "1" ]] || return 0
    [[ "${DEPLOY_MODE}" == "ipv4" || "${DEPLOY_MODE}" == "ipv6" ]] || return 0
    [[ "${ENDPOINT_FAMILY}" == "4" || "${ENDPOINT_FAMILY}" == "6" ]] || return 0
    have warp-cli || die "自动切换失败：warp-cli 不存在。"

    local result new_ip new_latency old_ip old_latency native_before
    result="$(select_best_endpoint_noninteractive "${ENDPOINT_FAMILY}" "${TUNNEL_PROTOCOL}")"
    IFS=$'\t' read -r new_ip new_latency <<<"${result}"
    [[ -n "${new_ip}" ]] || die "自动切换未找到候选端点。"

    old_ip="${ENDPOINT}"
    old_latency="${LAST_LATENCY}"

    if [[ "${new_ip}" == "${old_ip}" ]]; then
        LAST_LATENCY="${new_latency}"
        LAST_SWITCH_TIME="$(date '+%F %T %z')"
        save_state
        log "当前端点仍为最低延迟：${new_ip}，${new_latency} ms。"
        return 0
    fi

    if [[ "${DEPLOY_MODE}" == "ipv4" ]]; then
        native_before="$(public_ipv6)"
    else
        native_before="$(public_ipv4)"
    fi

    info "自动切换端点：${old_ip:-自动} -> ${new_ip}（${new_latency} ms）"
    warp_cli disconnect >/dev/null 2>&1 || true

    if ! set_custom_endpoint "${new_ip}" "${ENDPOINT_PORT}"; then
        warn "设置新端点失败，保留原端点。"
        [[ -n "${old_ip}" ]] && set_custom_endpoint "${old_ip}" "${ENDPOINT_PORT}" || true
        warp_cli connect >/dev/null 2>&1 || true
        return 1
    fi

    warp_cli connect >/dev/null 2>&1 || true
    if wait_connected && verify_target_family "${DEPLOY_MODE}" "${native_before}"; then
        ENDPOINT="${new_ip}"
        LAST_LATENCY="${new_latency}"
        LAST_SWITCH_TIME="$(date '+%F %T %z')"
        save_state
        log "自动切换成功，新端点：${new_ip}，${new_latency} ms。"
        return 0
    fi

    # 新端点不可用时恢复旧端点并重新连接。
    warn "新端点连接验证失败，正在恢复旧端点 ${old_ip:-自动选择}。"
    warp_cli disconnect >/dev/null 2>&1 || true
    if [[ -n "${old_ip}" ]]; then
        set_custom_endpoint "${old_ip}" "${ENDPOINT_PORT}" || reset_custom_endpoint
    else
        reset_custom_endpoint
    fi
    warp_cli connect >/dev/null 2>&1 || true
    wait_connected || true

    ENDPOINT="${old_ip}"
    LAST_LATENCY="${old_latency}"
    save_state
    return 1
}

# ------------------------------ 环境检查 -------------------------------------
status_word() {
    local ok="$1" yes_text="$2" no_text="$3"
    if [[ "${ok}" == "1" ]]; then
        printf '%b%s%b' "${C_GREEN}" "${yes_text}" "${C_RESET}"
    else
        printf '%b%s%b' "${C_RED}" "${no_text}" "${C_RESET}"
    fi
}

check_environment() {
    require_root
    load_state

    local os_name="未知" arch kernel tun_ok=0 systemd_ok=0 warp_ok=0 svc_ok=0 reg_ok=0
    local ipv4 ipv6 trace4 trace6 timer_state="关闭" mode_text="未部署"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_name="${PRETTY_NAME:-${ID:-未知}}"
    fi

    arch="$(uname -m)"
    kernel="$(uname -r)"
    [[ -c /dev/net/tun ]] && tun_ok=1
    have systemctl && [[ -d /run/systemd/system ]] && systemd_ok=1
    have warp-cli && warp_ok=1
    systemctl is-active --quiet warp-svc 2>/dev/null && svc_ok=1
    if (( warp_ok == 1 )) && is_registered; then reg_ok=1; fi

    ipv4="$(public_ipv4)"
    ipv6="$(public_ipv6)"
    trace4="$(cloudflare_trace 4 | grep -E '^(ip|loc|colo|warp)=' || true)"
    trace6="$(cloudflare_trace 6 | grep -E '^(ip|loc|colo|warp)=' || true)"

    case "${DEPLOY_MODE}" in
        ipv4) mode_text="WARP-IPv4" ;;
        ipv6) mode_text="WARP-IPv6" ;;
    esac
    systemctl is-enabled --quiet "${APP_NAME}-auto-switch.timer" 2>/dev/null && timer_state="开启"

    clear 2>/dev/null || true
    printf '%b╔════════════════════════════════════════════════════════════╗%b\n' "${C_BLUE}" "${C_RESET}"
    printf '%b║%b %-58s %b║%b\n' "${C_BLUE}" "${C_WHITE}" "WARP 环境检查报告" "${C_BLUE}" "${C_RESET}"
    printf '%b╠════════════════════════════════════════════════════════════╣%b\n' "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 系统：%-52s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${os_name}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 架构：%-16s 内核：%-27s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${arch}" "${kernel}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b systemd：%-12s TUN：%-12s WARP：%-12s %b║%b\n' \
        "${C_BLUE}" "${C_RESET}" \
        "$(status_word "${systemd_ok}" '正常' '异常')" \
        "$(status_word "${tun_ok}" '正常' '缺失')" \
        "$(status_word "${warp_ok}" '已安装' '未安装')" \
        "${C_BLUE}" "${C_RESET}"
    printf '%b║%b warp-svc：%-10s 注册：%-12s 连接：%-12s %b║%b\n' \
        "${C_BLUE}" "${C_RESET}" \
        "$(status_word "${svc_ok}" '运行中' '未运行')" \
        "$(status_word "${reg_ok}" '正常' '未注册')" \
        "$(status_word "$([[ ${warp_ok} -eq 1 ]] && is_warp_connected && echo 1 || echo 0)" 'Connected' 'Disconnected')" \
        "${C_BLUE}" "${C_RESET}"
    printf '%b╠════════════════════════════════════════════════════════════╣%b\n' "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 部署模式：%-16s 自动切换：%-20s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${mode_text}" "${timer_state}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 当前端点：%-46s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${ENDPOINT:-未设置}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 协议/端口：%-12s / %-29s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${TUNNEL_PROTOCOL}" "${ENDPOINT_PORT}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b 最近延迟：%-14s 最近检查：%-25s %b║%b\n' "${C_BLUE}" "${C_RESET}" "${LAST_LATENCY:-未知}" "${LAST_SWITCH_TIME:-从未}" "${C_BLUE}" "${C_RESET}"
    printf '%b╚════════════════════════════════════════════════════════════╝%b\n' "${C_BLUE}" "${C_RESET}"

    printf '\n%b--- 公网出口 ---%b\n' "${C_CYAN}" "${C_RESET}"
    printf 'IPv4：%s\n' "${ipv4:-不可用}"
    printf 'IPv6：%s\n' "${ipv6:-不可用}"

    printf '\n%b--- IPv4 Cloudflare Trace ---%b\n%s\n' "${C_CYAN}" "${C_RESET}" "${trace4:-不可用}"
    printf '\n%b--- IPv6 Cloudflare Trace ---%b\n%s\n' "${C_CYAN}" "${C_RESET}" "${trace6:-不可用}"

    if (( warp_ok == 1 )); then
        printf '\n%b--- WARP 状态 ---%b\n' "${C_CYAN}" "${C_RESET}"
        warp_cli status 2>&1 || true
        printf '\n%b--- Split Tunnel IP 列表 ---%b\n' "${C_CYAN}" "${C_RESET}"
        split_list || true
    fi

    if systemctl is-enabled --quiet "${APP_NAME}-auto-switch.timer" 2>/dev/null; then
        printf '\n%b--- 自动切换定时器 ---%b\n' "${C_CYAN}" "${C_RESET}"
        systemctl list-timers "${APP_NAME}-auto-switch.timer" --no-pager || true
    fi
}

# ------------------------------- 卸载流程 ------------------------------------
remove_deployment() {
    require_root
    require_systemd
    if have flock; then
        acquire_operation_lock
    fi
    load_state

    cancel_rollback
    systemctl disable --now "${APP_NAME}-auto-switch.timer" >/dev/null 2>&1 || true
    systemctl disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
    rm -f "${AUTO_SERVICE}" "${AUTO_TIMER}" "${BOOT_SERVICE}"
    systemctl daemon-reload

    if have warp-cli; then
        warp_cli disconnect >/dev/null 2>&1 || true
        restore_original_split_state || true
        reset_custom_endpoint
        warp_cli registration delete >/dev/null 2>&1 || true
    fi

    rm -f "${SYSCTL_FILE}"
    if [[ "${STATE_INITIALIZED}" == "1" ]]; then
        sysctl -q -w "net.ipv6.conf.all.disable_ipv6=${OLD_ALL_IPV6:-0}" || true
        sysctl -q -w "net.ipv6.conf.default.disable_ipv6=${OLD_DEFAULT_IPV6:-0}" || true
    fi

    systemctl disable --now warp-svc >/dev/null 2>&1 || true
    uninstall_warp_package
    rm -rf "${STATE_DIR}"

    local current
    current="$(readlink -f "${BASH_SOURCE[0]}")"
    if [[ "${current}" != "${INSTALL_PATH}" ]]; then
        rm -f "${INSTALL_PATH}"
    else
        # 正在执行的脚本稍后自删除，避免当前进程读取异常。
        (sleep 1; rm -f "${INSTALL_PATH}") >/dev/null 2>&1 &
    fi

    log "WARP 客户端、分流规则、自动切换任务和本脚本部署已卸载。"
}

confirm_remove() {
    if [[ ! -t 0 ]]; then
        return 0
    fi

    printf '%b卸载会断开 WARP 并删除 cloudflare-warp 软件包，确认继续？[y/N]：%b' \
        "${C_RED}" "${C_RESET}"
    local answer
    read -r answer || true
    [[ "${answer}" =~ ^[Yy]$ ]]
}

# -------------------------------- 菜单界面 ------------------------------------
menu_status_line() {
    load_state
    local mode="未安装" connection="Disconnected" auto="关闭"

    case "${DEPLOY_MODE}" in
        ipv4) mode="WARP-IPv4" ;;
        ipv6) mode="WARP-IPv6" ;;
    esac
    if have warp-cli && is_warp_connected; then connection="Connected"; fi
    systemctl is-enabled --quiet "${APP_NAME}-auto-switch.timer" 2>/dev/null && auto="开启"

    printf '%b状态：%b模式=%b%s%b  连接=%b%s%b  自动切换=%b%s%b\n' \
        "${C_DIM}" "${C_RESET}" "${C_CYAN}" "${mode}" "${C_RESET}" \
        "$([[ "${connection}" == "Connected" ]] && printf '%b' "${C_GREEN}" || printf '%b' "${C_RED}")" \
        "${connection}" "${C_RESET}" \
        "$([[ "${auto}" == "开启" ]] && printf '%b' "${C_GREEN}" || printf '%b' "${C_YELLOW}")" \
        "${auto}" "${C_RESET}"
}

show_menu() {
    clear 2>/dev/null || true
    printf '%b╔══════════════════════════════════════════════════════╗%b\n' "${C_BLUE}" "${C_RESET}"
    printf '%b║%b        %bCloudflare WARP 双栈出口管理脚本%b             %b║%b\n' \
        "${C_BLUE}" "${C_RESET}" "${C_WHITE}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b                  Version %-8s                    %b║%b\n' \
        "${C_BLUE}" "${C_DIM}" "${SCRIPT_VERSION}" "${C_BLUE}" "${C_RESET}"
    printf '%b╠══════════════════════════════════════════════════════╣%b\n' "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b1%b. 安装 WARP-IPv4                                  %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_GREEN}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b2%b. 安装 WARP-IPv6                                  %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_GREEN}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b3%b. 卸载 WARP                                       %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_RED}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b4%b. 开启延迟自动切换                               %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_YELLOW}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b5%b. 关闭延迟自动切换                               %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_YELLOW}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b6%b. 检查 WARP 环境                                  %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_MAGENTA}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b║%b  %b0%b. 退出脚本                                       %b║%b\n' "${C_BLUE}" "${C_CYAN}" "${C_WHITE}" "${C_RESET}" "${C_BLUE}" "${C_RESET}"
    printf '%b╚══════════════════════════════════════════════════════╝%b\n' "${C_BLUE}" "${C_RESET}"
    menu_status_line
}

menu_loop() {
    require_root
    require_systemd

    while true; do
        show_menu
        printf '\n%b请输入选项 [0-6]：%b' "${C_YELLOW}" "${C_RESET}"
        local choice
        read -r choice || choice="0"
        printf '\n'

        case "${choice}" in
            1)
                (install_deployment ipv4) || warn "WARP-IPv4 安装未完成。"
                pause_screen
                ;;
            2)
                (install_deployment ipv6) || warn "WARP-IPv6 安装未完成。"
                pause_screen
                ;;
            3)
                if confirm_remove; then
                    (remove_deployment) || warn "卸载过程中发生错误。"
                else
                    info "已取消卸载。"
                fi
                pause_screen
                ;;
            4)
                (enable_auto_switch) || warn "开启自动切换失败。"
                pause_screen
                ;;
            5)
                (disable_auto_switch) || warn "关闭自动切换失败。"
                pause_screen
                ;;
            6)
                (check_environment) || warn "环境检查过程中发生错误。"
                pause_screen
                ;;
            0)
                log "已退出脚本。"
                return 0
                ;;
            *)
                warn "请输入 0 到 6 之间的有效选项。"
                sleep 1
                ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：
  ${APP_NAME}                         打开交互菜单
  ${APP_NAME} install-ipv4            安装/切换为 WARP-IPv4
  ${APP_NAME} install-ipv6            安装/切换为 WARP-IPv6
  ${APP_NAME} remove                  卸载 WARP
  ${APP_NAME} auto-enable             开启每 10 分钟延迟自动切换
  ${APP_NAME} auto-disable            关闭延迟自动切换
  ${APP_NAME} check                   检查 WARP 环境
  ${APP_NAME} ensure                  根据保存状态恢复连接（供 systemd 使用）
  ${APP_NAME} auto-switch             执行一次自动优选（供 timer 使用）
EOF
}

main() {
    local action="${1:-menu}"
    case "${action}" in
        menu)           menu_loop ;;
        install-ipv4)   install_deployment ipv4 ;;
        install-ipv6)   install_deployment ipv6 ;;
        remove|uninstall)
            if [[ "${FORCE:-0}" == "1" ]] || confirm_remove; then
                remove_deployment
            else
                info "已取消卸载。"
            fi
            ;;
        auto-enable)    enable_auto_switch ;;
        auto-disable)   disable_auto_switch ;;
        check|status)   check_environment ;;
        ensure)         ensure_deployment ;;
        auto-switch)    auto_switch_endpoint ;;
        help|-h|--help) usage ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
