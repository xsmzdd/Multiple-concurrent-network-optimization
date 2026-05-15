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

    setup_cgroup
    move_processes_once
    install_daemon_script
    install_systemd_service
    show_status

    log "完成。realm、gost、ehco 会被后台服务持续迁移进 ${CGROUP_PATH}。"
}

main "$@"
