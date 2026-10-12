#!/usr/bin/env bash
# Xiandan-friendly low-memory helper (cgroup v2 + swap)
# Does NOT edit forwarding rules, kill, or restart proxy processes.
set -Eeuo pipefail

TAG='[xiandan-lowmem]'
ROOT=/sys/fs/cgroup
CG="$ROOT/proxy-lowmem"
STATE=/var/lib/xiandan-lowmem
DAEMON=/usr/local/sbin/xiandan-lowmem-watch.sh
SERVICE=/etc/systemd/system/xiandan-lowmem-watch.service
SLICE_FILE=/etc/systemd/system/xiandan-proxy.slice
OLD_SERVICE=cgv2-proxy-lowmem.service
OLD_UNIT=/etc/systemd/system/cgv2-proxy-lowmem.service
SWAPFILE=/swapfile-xiandan-lowmem
SWAP_TARGET_MB=2048
# Soft pressure limit for the aggregate of *newly charged* pages. Not a hard cap.
MEMORY_HIGH=${MEMORY_HIGH:-512M}
GOGC_VALUE=${GOGC_VALUE:-75}
CHECK_INTERVAL=${CHECK_INTERVAL:-15}

log(){ printf '%s %s\n' "$TAG" "$*"; }
warn(){ printf '%s WARNING: %s\n' "$TAG" "$*" >&2; }
die(){ printf '%s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die '请使用 root 运行'
command -v systemctl >/dev/null || die '需要 systemd'
[[ -f "$ROOT/cgroup.controllers" && "$(stat -fc %T "$ROOT")" == cgroup2fs ]] || die '需要已启用 cgroup v2；不自动修改 GRUB 或重启服务器'
[[ -f /proc/swaps ]] || die '系统不支持 Swap'
[[ $GOGC_VALUE =~ ^[0-9]+$ ]] || die 'GOGC_VALUE 必须为非负整数'
[[ $MEMORY_HIGH =~ ^[0-9]+[KMG]$ ]] || die 'MEMORY_HIGH 格式示例 512M'

# Add Swap only when the machine has none, leaving existing Swap unchanged.
setup_swap(){
  local active_kb available_kb
  active_kb=$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps)
  if (( active_kb > 0 )); then
    log "已有启用 Swap：$(awk -v n="$active_kb" 'BEGIN{printf "%.1f MiB",n/1024}')；不修改"
    return
  fi
  [[ ! -e "$SWAPFILE" ]] || die "$SWAPFILE 已存在但未启用；请手工检查，避免覆盖文件"
  available_kb=$(df -Pk / | awk 'END {print $4}')
  (( available_kb >= (SWAP_TARGET_MB+256)*1024 )) || die '根分区空间不足，至少需约 2304 MiB 可用空间创建 Swap'
  log '未检测到 Swap，创建 2048 MiB 的 Swap 文件'
  if command -v fallocate >/dev/null; then
    fallocate -l "${SWAP_TARGET_MB}M" "$SWAPFILE" || { rm -f "$SWAPFILE"; die 'fallocate 失败'; }
  else
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_TARGET_MB" status=progress || { rm -f "$SWAPFILE"; die '创建 Swap 失败'; }
  fi
  chmod 600 "$SWAPFILE"
  if ! mkswap "$SWAPFILE" >/dev/null || ! swapon "$SWAPFILE"; then
    rm -f "$SWAPFILE"
    die '启用 Swap 失败（文件系统可能不支持）。未修改 fstab'
  fi
  if ! grep -Eq "^[[:space:]]*${SWAPFILE//\//\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
  fi
  log "已启用 Swap：$(swapon --show --noheadings --bytes --output=SIZE | awk '{s+=$1} END{printf "%.0f MiB",s/1048576}')"
}

# Old installs used a 256 MiB hard cap, which can OOM-kill busy proxies.
disable_old_service(){
  if systemctl is-enabled --quiet "$OLD_SERVICE" 2>/dev/null || systemctl is-active --quiet "$OLD_SERVICE" 2>/dev/null; then
    log '停用旧版 cgv2-proxy-lowmem 守护程序（不停止代理）'
    systemctl disable --now "$OLD_SERVICE" || warn '旧版服务停用失败；请检查'
  fi
}

setup_cgroup(){
  if grep -qw memory "$ROOT/cgroup.controllers"; then
    { echo +memory > "$ROOT/cgroup.subtree_control"; } 2>/dev/null || true
  fi
  mkdir -p "$CG"
  [[ -f "$CG/memory.high" && -f "$CG/memory.max" ]] || die 'cgroup memory controller 不可用'
  # Clear obsolete hard cap first, before configuring softer reclaim pressure.
  echo max > "$CG/memory.max"
  echo "$MEMORY_HIGH" > "$CG/memory.high"
  [[ -f "$CG/memory.swap.max" ]] && echo max > "$CG/memory.swap.max"
  log "旧式 PID 迁移组: memory.high=$MEMORY_HIGH, memory.max=max (不设硬限制)"
}

# Determine whether a process is currently managed by systemd's service cgroup.
# Do not forcibly move those: it breaks systemd's resource accounting and lifecycle.
migrate_unmanaged_once(){
  local name pid cgline count=0
  for name in gost realm ehco; do
    while read -r pid; do
      [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cgroup ]] || continue
      cgline=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
      [[ $cgline == *'/proxy-lowmem'* ]] && continue
      if [[ $cgline =~ \.service(/|$) ]]; then
        continue
      fi
      if echo "$pid" > "$CG/cgroup.procs" 2>/dev/null; then
        ((count+=1))
      fi
    done < <(pgrep -x "$name" || true)
  done
  (( count == 0 )) || log "已迁移 $count 个非 systemd 服务进程（既有内存不会立刻重新计费）"
}

# For managed Xiandan per-port units, preserve ExecStart and panel's CRUD semantics.
# Drop-ins remain when the vendor regenerates unit file; no forced restarts.
setup_slice(){
  cat > "$SLICE_FILE" <<EOF
[Unit]
Description=Xiandan proxy aggregate soft memory pressure

[Slice]
MemoryAccounting=yes
MemoryHigh=$MEMORY_HIGH
MemoryMax=infinity
MemorySwapMax=infinity
EOF
  systemctl daemon-reload
  systemctl start xiandan-proxy.slice
}

install_unit_dropins(){
  local file unit dir total=0 changed=0 desired
  shopt -s nullglob
  for file in /etc/xiandan/service/xiandan*xiandan.service; do
    unit=${file##*/}
    [[ $unit =~ ^xiandan[0-9]+xiandan\.service$ ]] || continue
    # Apply only if this exact unit is visible to systemd. Unloaded files are not modified.
    if [[ "$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)" != loaded ]]; then
      continue
    fi
    dir="/etc/systemd/system/$unit.d"
    mkdir -p "$dir"
    desired=$(cat <<EOF
# Managed by xiandan-lowmem. No ExecStart override.
[Service]
Slice=xiandan-proxy.slice
Environment="GOGC=$GOGC_VALUE"
MemoryAccounting=yes
MemoryHigh=96M
MemoryMax=infinity
MemorySwapMax=infinity
EOF
)
    if [[ ! -f "$dir/90-xiandan-lowmem.conf" ]] || [[ "$(cat "$dir/90-xiandan-lowmem.conf")" != "$desired" ]]; then
      printf '%s\n' "$desired" > "$dir/90-xiandan-lowmem.conf"
      ((changed+=1))
    fi
    ((total+=1))
  done
  shopt -u nullglob
  if (( changed > 0 )); then
    systemctl daemon-reload
    log "已更新 $changed 个 drop-in（共识别 $total 个服务）；只在对应服务下次启动时生效"
  fi
}

install_watcher(){
  mkdir -p "$STATE"
  cat > "$DAEMON" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export MEMORY_HIGH='$MEMORY_HIGH' GOGC_VALUE='$GOGC_VALUE' CHECK_INTERVAL='$CHECK_INTERVAL'
exec /usr/local/sbin/xiandan-lowmem-control.sh --watch
EOF
  chmod 700 "$DAEMON"
  cat > "$SERVICE" <<EOF
[Unit]
Description=Xiandan low-memory proxy monitor (does not restart proxies)
After=local-fs.target

[Service]
Type=simple
ExecStart=$DAEMON
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xiandan-lowmem-watch.service
  systemctl restart xiandan-lowmem-watch.service
}

status(){
  echo '==== Swap ===='
  swapon --show
  free -h
  echo '==== 迁移 cgroup ===='
  if [[ -d "$CG" ]]; then
    for f in memory.high memory.max memory.current memory.swap.current memory.events; do
      [[ ! -f "$CG/$f" ]] || { echo "-- $f"; cat "$CG/$f"; }
    done
    [[ ! -f "$CG/cgroup.procs" ]] || { printf 'cgroup 进程数: '; wc -l < "$CG/cgroup.procs"; }
  fi
  echo '==== Watcher ===='
  systemctl --no-pager --full status xiandan-lowmem-watch.service || true
  echo '提示：当前既有进程不会因迁移而立即进入 Swap；systemd 的 GOGC 环境变量在对应服务下次启动时生效。'
}

case "${1:-install}" in
  install)
    setup_swap
    disable_old_service
    setup_cgroup
    # Store the complete script as the stable watcher backend; protects against /tmp removal.
    if [[ "$(readlink -f "$0")" != /usr/local/sbin/xiandan-lowmem-control.sh ]]; then
      install -m 700 "$(readlink -f "$0")" /usr/local/sbin/xiandan-lowmem-control.sh
    fi
    setup_slice
    install_unit_dropins
    migrate_unmanaged_once
    install_watcher
    status
    ;;
  --watch)
    while :; do
      setup_cgroup >/dev/null
      install_unit_dropins >/dev/null
      migrate_unmanaged_once
      sleep "$CHECK_INTERVAL"
    done
    ;;
  status) status ;;
  *) die '用法: bash script.sh [install|status]' ;;
esac
