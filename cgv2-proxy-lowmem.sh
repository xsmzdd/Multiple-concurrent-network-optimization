#!/usr/bin/env bash
set -euo pipefail

CGROUP_NAME="proxy-lowmem"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"

MEMORY_MAX="256M"
MEMORY_HIGH="220M"
MEMORY_SWAP_MAX="max"

PROCESS_NAMES=("realm" "gost" "ehco")

DAEMON_SCRIPT="/usr/local/sbin/cgv2-proxy-lowmem-daemon.sh"
SERVICE_FILE="/etc/systemd/system/cgv2-proxy-lowmem.service"

log() {
    echo "[cgv2-proxy-lowmem] $*"
}

die() {
    echo "[cgv2-proxy-lowmem] ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 运行，例如：sudo bash $0"
    fi
}

is_cgroup_v2_enabled() {
    [[ -f /sys/fs/cgroup/cgroup.controllers ]] && \
    [[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]]
}

try_enable_cgroup_v2() {
    log "当前系统未启用 cgroup v2。"

    if ! command -v apt-get >/dev/null 2>&1; then
        die "未检测到 apt-get。此脚本按 Debian 系统编写。"
    fi

    log "安装必要组件：systemd、cgroup-tools、grub 工具。"
    apt-get update
    apt-get install -y systemd cgroup-tools

    if [[ ! -f /etc/default/grub ]]; then
        die "未找到 /etc/default/grub，无法自动配置 cgroup v2。"
    fi

    log "尝试修改 GRUB，启用统一 cgroup v2。"

    if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if ! grep -q 'systemd.unified_cgroup_hierarchy=1' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all /' /etc/default/grub
        fi
    else
        echo 'GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"' >> /etc/default/grub
    fi

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        die "未找到 update-grub 或 grub-mkconfig，请手动更新 GRUB。"
    fi

    log "cgroup v2 已写入启动参数。请重启系统后再次运行本脚本："
    echo
    echo "    sudo reboot"
    echo
    exit 0
}

ensure_swap() {
    if [[ -d "/proc/vz" ]]; then
        die "检测到 OpenVZ 环境，不支持自行创建 swap。"
    fi

    # 当前已经启用 swap，直接返回
    if swapon --show | awk 'NR>1 {found=1} END {exit !found}'; then
        log "检测到系统已有启用中的 swap："
        swapon --show
        return
    fi

    # 当前没有启用 swap，但 /etc/fstab 里已有 swap 配置，先尝试 swapon -a
    if grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
        log "检测到 /etc/fstab 中已有 swap 配置，但当前未启用。正在尝试 swapon -a..."

        if swapon -a 2>/tmp/cgv2-swapon-error.log; then
            if swapon --show | awk 'NR>1 {found=1} END {exit !found}'; then
                log "已有 swap 配置已成功启用："
                swapon --show
                return
            fi
        fi

        log "已有 swap 配置启用失败，错误信息如下："
        cat /tmp/cgv2-swapon-error.log || true

        log "将继续创建新的 /swapfile。"
    fi

    log "未检测到已启用的 swap。"
    echo
    read -rp "请输入要创建的 swap 大小，单位 MB，例如 2048 表示 2G: " swapsize

    if [[ -z "${swapsize}" ]]; then
        die "swap 大小不能为空。"
    fi

    if [[ ! "${swapsize}" =~ ^[0-9]+$ ]]; then
        die "请输入纯数字，单位为 MB，例如：1024、2048、4096。"
    fi

    # 如果 /swapfile 已存在，优先尝试启用
    if [[ -e /swapfile ]]; then
        log "检测到 /swapfile 已存在，但当前未启用。正在尝试启用已有 /swapfile..."

        chmod 600 /swapfile || true

        if swapon /swapfile 2>/tmp/cgv2-swapon-error.log; then
            grep -qE '^/swapfile[[:space:]]+' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
            log "/swapfile 已成功启用："
            swapon --show
            return
        fi

        log "已有 /swapfile 启用失败，错误信息如下："
        cat /tmp/cgv2-swapon-error.log || true

        log "删除无效的 /swapfile 并重新创建。"
        rm -f /swapfile
        sed -i '\#^/swapfile[[:space:]]#d' /etc/fstab
    fi

    log "正在创建 /swapfile，大小：${swapsize}M"

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swapsize}M" /swapfile
    else
        dd if=/dev/zero of=/swapfile bs=1M count="${swapsize}" status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile

    # 有些机器 fallocate 创建的 swapfile 无法 swapon，失败后自动改用 dd
    if ! swapon /swapfile 2>/tmp/cgv2-swapon-error.log; then
        log "fallocate 创建的 swapfile 启用失败，尝试改用 dd 重新创建..."

        cat /tmp/cgv2-swapon-error.log || true

        rm -f /swapfile
        dd if=/dev/zero of=/swapfile bs=1M count="${swapsize}" status=progress
        chmod 600 /swapfile
        mkswap /swapfile

        if ! swapon /swapfile 2>/tmp/cgv2-swapon-error.log; then
            log "dd 创建的 swapfile 仍然启用失败，错误信息如下："
            cat /tmp/cgv2-swapon-error.log || true
            rm -f /swapfile
            die "当前系统可能不支持 swapfile，可能是 OpenVZ/LXC/Docker/overlay 文件系统限制。"
        fi
    fi

    if ! grep -qE '^/swapfile[[:space:]]+' /etc/fstab; then
        echo '/swapfile none swap defaults 0 0' >> /etc/fstab
    fi

    log "swap 创建成功："
    swapon --show
    cat /proc/meminfo | grep Swap
}

enable_memory_controller() {
    if [[ -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
        if grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
            echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        fi
    fi
}

setup_cgroup() {
    enable_memory_controller

    mkdir -p "${CGROUP_PATH}"

    if [[ ! -f "${CGROUP_PATH}/memory.max" ]]; then
        die "当前 cgroup 中没有 memory.max，memory controller 可能未启用。"
    fi

    log "设置 cgroup：${CGROUP_PATH}"

    echo "${MEMORY_HIGH}" > "${CGROUP_PATH}/memory.high"
    echo "${MEMORY_MAX}" > "${CGROUP_PATH}/memory.max"

    if [[ -f "${CGROUP_PATH}/memory.swap.max" ]]; then
        echo "${MEMORY_SWAP_MAX}" > "${CGROUP_PATH}/memory.swap.max"
    else
        log "当前内核不支持 memory.swap.max，跳过 swap 上限设置。"
    fi

    log "当前 cgroup 内存限制："
    echo "memory.high=$(cat "${CGROUP_PATH}/memory.high")"
    echo "memory.max=$(cat "${CGROUP_PATH}/memory.max")"

    if [[ -f "${CGROUP_PATH}/memory.swap.max" ]]; then
        echo "memory.swap.max=$(cat "${CGROUP_PATH}/memory.swap.max")"
    fi
}

move_processes_once() {
    local name
    local pid

    for name in "${PROCESS_NAMES[@]}"; do
        while read -r pid; do
            [[ -z "${pid}" ]] && continue

            if [[ -d "/proc/${pid}" ]]; then
                echo "${pid}" > "${CGROUP_PATH}/cgroup.procs" 2>/dev/null || true
                log "已迁移进程：${name}, PID=${pid}"
            fi
        done < <(pgrep -x "${name}" || true)
    done
}

install_daemon_script() {
    cat > "${DAEMON_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CGROUP_NAME="proxy-lowmem"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"

MEMORY_MAX="256M"
MEMORY_HIGH="220M"
MEMORY_SWAP_MAX="max"

PROCESS_NAMES=("realm" "gost" "ehco")

log() {
    echo "[cgv2-proxy-lowmem-daemon] $*"
}

enable_memory_controller() {
    if [[ -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
        if grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
            echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        fi
    fi
}

setup_cgroup() {
    enable_memory_controller

    mkdir -p "${CGROUP_PATH}"

    if [[ -f "${CGROUP_PATH}/memory.high" ]]; then
        echo "${MEMORY_HIGH}" > "${CGROUP_PATH}/memory.high"
    fi

    if [[ -f "${CGROUP_PATH}/memory.max" ]]; then
        echo "${MEMORY_MAX}" > "${CGROUP_PATH}/memory.max"
    fi

    if [[ -f "${CGROUP_PATH}/memory.swap.max" ]]; then
        echo "${MEMORY_SWAP_MAX}" > "${CGROUP_PATH}/memory.swap.max"
    fi
}

move_processes_once() {
    local name
    local pid

    for name in "${PROCESS_NAMES[@]}"; do
        while read -r pid; do
            [[ -z "${pid}" ]] && continue

            if [[ -d "/proc/${pid}" ]]; then
                echo "${pid}" > "${CGROUP_PATH}/cgroup.procs" 2>/dev/null || true
            fi
        done < <(pgrep -x "${name}" || true)
    done
}

main() {
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log "cgroup v2 未启用，退出。"
        exit 1
    fi

    while true; do
        setup_cgroup
        move_processes_once
        sleep 10
    done
}

main "$@"
EOF

    chmod +x "${DAEMON_SCRIPT}"
}

install_systemd_service() {
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Move realm gost ehco into cgroup v2 low memory group
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${DAEMON_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now cgv2-proxy-lowmem.service
}

show_status() {
    echo
    log "后台服务状态："
    systemctl --no-pager --full status cgv2-proxy-lowmem.service || true

    echo
    log "cgroup 进程列表："
    if [[ -f "${CGROUP_PATH}/cgroup.procs" ]]; then
        while read -r pid; do
            [[ -z "${pid}" ]] && continue
            ps -p "${pid}" -o pid,comm,rss,vsz --no-headers || true
        done < "${CGROUP_PATH}/cgroup.procs"
    fi

    echo
    log "查看实时日志："
    echo "journalctl -u cgv2-proxy-lowmem.service -f"

    echo
    log "查看 cgroup 内存状态："
    echo "cat ${CGROUP_PATH}/memory.current"
    echo "cat ${CGROUP_PATH}/memory.stat"

    echo
    log "查看 cgroup 内存限制："
    echo "cat ${CGROUP_PATH}/memory.high"
    echo "cat ${CGROUP_PATH}/memory.max"
    echo "cat ${CGROUP_PATH}/memory.swap.max"
}

main() {
    require_root

    if ! is_cgroup_v2_enabled; then
        try_enable_cgroup_v2
    fi

    ensure_swap
    setup_cgroup
    move_processes_once
    install_daemon_script
    install_systemd_service
    show_status

    log "完成。realm、gost、ehco 会被后台服务持续迁移进 ${CGROUP_PATH}。"
}

main "$@"
