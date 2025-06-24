#!/usr/bin/env bash
set -e

# ========== 日志配置 ==========
LOG_FILE="/var/log/xanmod_optimization.log"
{
echo "================================================================"
echo "🕒 脚本启动时间: $(date)"
echo "🚀 开始：出口服务器网络优化脚本（XanMod + BBRv3 + 动态延迟优化）"
echo "💾 日志文件: $LOG_FILE"
echo "================================================================"

# 清空旧日志
> "$LOG_FILE"

# ========== 1. 安装必要依赖 ==========
install_dependencies() {
    echo "🔍 检查并安装必要依赖..."
    REQUIRED_PKGS=("curl" "wget" "gpg" "dirmngr" "iproute2" "ca-certificates" "bc" "iputils-ping" "util-linux")
    MISSING_PKGS=()

    # 检查缺失的包（安全方式）
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    # 安装缺失的依赖
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo "📦 安装依赖: ${MISSING_PKGS[*]}..."
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "${MISSING_PKGS[@]}" </dev/null
        echo "✅ 依赖安装完成"
    else
        echo "✅ 所有依赖已安装"
    fi
}

install_dependencies

# ========== 2. 内核检测 ==========
KERNEL_VERSION="6.15.3-x64v3-xanmod1"
CURRENT_KERNEL=$(uname -r)
if [[ "$CURRENT_KERNEL" == *"$KERNEL_VERSION"* ]]; then
    IS_XANMOD=1
else
    IS_XANMOD=0
fi
echo "ℹ️ 当前内核: $CURRENT_KERNEL"
echo "ℹ️ 目标内核: $KERNEL_VERSION"
echo "ℹ️ 内核匹配状态: $([ $IS_XANMOD -eq 1 ] && echo "是" || echo "否")"

# ========== 3. 配置备份 ==========
echo "🔧 备份系统配置..."
BACKUP_TIME=$(date +%Y%m%d_%H%M%S)
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$BACKUP_TIME
[ -f /etc/rc.local ] && cp /etc/rc.local /etc/rc.local.bak.$BACKUP_TIME
mkdir -p /etc/sysctl.d/backups
echo "✅ 备份完成：sysctl.conf 和 rc.local"
echo "📌 备份文件:"
echo "  - /etc/sysctl.conf.bak.$BACKUP_TIME"
echo "  - /etc/rc.local.bak.$BACKUP_TIME"

# ========== 4. 安装 XanMod 内核 ==========
if [ "$IS_XANMOD" -eq 0 ]; then
  echo "📥 安装 XanMod 内核 $KERNEL_VERSION..."
  
  # 确保使用https访问仓库
  echo 'deb [signed-by=/usr/share/keyrings/xanmod-kernel.gpg] https://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
  
# 下载并安装GPG密钥
echo "🔑 下载XanMod GPG密钥..."
if ! wget -qO - https://dl.xanmod.org/gpg.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-kernel.gpg >/dev/null 2>/dev/null; then
  echo "⚠️ 主GPG密钥下载失败，尝试备用源..."
  wget -qO - https://203.55.176.82:21569/down/BVwPEZcfSAlF.key | gpg --dearmor -o /usr/share/keyrings/xanmod-kernel.gpg 2>/dev/null
fi
  
  # 更新并安装内核
  echo "🔄 更新软件包列表..."
  apt update >/dev/null 2>&1
  echo "⬇️ 安装内核..."
  DEBIAN_FRONTEND=noninteractive apt install -y linux-image-$KERNEL_VERSION </dev/null
  
  echo "📌 设置默认启动 XanMod 内核..."
  grub-set-default 0
  update-grub
  echo "✅ 内核安装完成，重启后生效"
else
  echo "✅ 已运行目标内核: $KERNEL_VERSION"
fi

# ========== 5. 内存自适应计算 ==========
calculate_memory_params() {
  # 获取内存信息（KB）
  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  
  # 计算TCP内存参数（基于内存页）
  PAGES=$(getconf PAGESIZE)
  TOTAL_PAGES=$((MEM_KB * 1024 / PAGES))
  
  TCP_MEM_MIN=$((TOTAL_PAGES / 4))
  TCP_MEM_PRESSURE=$((TOTAL_PAGES / 2))
  TCP_MEM_MAX=$TOTAL_PAGES
  
  # 计算连接跟踪最大值
  CONNTRACK_MAX=$((MEM_KB * 1024 / 16384))
  [ $CONNTRACK_MAX -lt 65536 ] && CONNTRACK_MAX=65536
  [ $CONNTRACK_MAX -gt 1048576 ] && CONNTRACK_MAX=1048576
  
  # 计算TCP缓冲区
  if [ $MEM_KB -le 1048576 ]; then  # <=1GB
    TCP_RMEM="4096 87380 262144"
    TCP_WMEM="4096 65536 262144"
  elif [ $MEM_KB -le 4194304 ]; then  # <=4GB
    TCP_RMEM="8192 131072 524288"
    TCP_WMEM="8192 131072 524288"
  elif [ $MEM_KB -le 8388608 ]; then  # <=8GB
    TCP_RMEM="16384 262144 1048576"
    TCP_WMEM="16384 262144 1048576"
  else  # >8GB
    TCP_RMEM="32768 524288 2097152"
    TCP_WMEM="32768 524288 2097152"
  fi
  
  echo "$TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
  echo "$CONNTRACK_MAX"
  echo "$TCP_RMEM"
  echo "$TCP_WMEM"
}

# 计算内存参数
echo "🧠 计算内存优化参数..."
read TCP_MEM CONNTRACK_MAX TCP_RMEM TCP_WMEM <<< $(calculate_memory_params)
echo "📊 内存优化参数:"
echo "  TCP_MEM: $TCP_MEM"
echo "  CONNTRACK_MAX: $CONNTRACK_MAX"
echo "  TCP_RMEM: $TCP_RMEM"
echo "  TCP_WMEM: $TCP_WMEM"

# ========== 6. 网络栈检测 ==========
HAS_IPV4=0
HAS_IPV6=0

# 检测IPv4支持
if ip -4 addr show | grep -q "inet"; then
  HAS_IPV4=1
fi

# 检测IPv6支持
if ip -6 addr show | grep -q "inet6"; then
  HAS_IPV6=1
fi

echo -e "\n📡 网络栈检测结果:"
echo "IPv4 支持: $([ "$HAS_IPV4" -eq 1 ] && echo "✅" || echo "❌")"
echo "IPv6 支持: $([ "$HAS_IPV6" -eq 1 ] && echo "✅" || echo "❌")"

# ========== [新增] 7. 用户输入延迟值 ==========
IPV4_LATENCY=""
IPV6_LATENCY=""

if [ "$HAS_IPV4" -eq 1 ]; then
  read -p "🔢 请输入 IPv4 网络延迟 (单位：毫秒): " IPV4_LATENCY
  # 验证输入
  if ! [[ $IPV4_LATENCY =~ ^[0-9]+$ ]] || [ $IPV4_LATENCY -lt 1 ] || [ $IPV4_LATENCY -gt 1000 ]; then
      echo "⚠️ 输入无效，使用默认值 100ms"
      IPV4_LATENCY=100
  fi
  echo "📝 IPv4 延迟设置: ${IPV4_LATENCY}ms"
fi

if [ "$HAS_IPV6" -eq 1 ]; then
  read -p "🔢 请输入 IPv6 网络延迟 (单位：毫秒): " IPV6_LATENCY
  if ! [[ $IPV6_LATENCY =~ ^[0-9]+$ ]] || [ $IPV6_LATENCY -lt 1 ] || [ $IPV6_LATENCY -gt 1000 ]; then
      echo "⚠️ 输入无效，使用默认值 100ms"
      IPV6_LATENCY=100
  fi
  echo "📝 IPv6 延迟设置: ${IPV6_LATENCY}ms"
fi

# ========== 8. 延迟优化方案 ==========
apply_latency_optimization() {
  local latency=$1
  local proto=$2
  local config_file="/etc/sysctl.d/99-${proto}-optimize.conf"
  
  # 验证延迟值为数字
  if ! [[ $latency =~ ^[0-9]+$ ]]; then
    echo "⚠️ 无效延迟值 '$latency'，使用默认值100"
    latency=100
  fi
  
  # 清除旧配置
  rm -f $config_file
  
  # 基础优化参数 (所有方案通用)
  cat <<EOF > $config_file
# ===== $proto 基础网络优化 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.tcp_mem = $TCP_MEM
EOF

  # 根据延迟选择优化方案
  if [ $latency -le 25 ]; then
    # 0-25ms: 超低延迟优化
    echo "🚀 应用 $proto 优化方案: 超低延迟 (0-25ms)"
    cat <<EOF >> $config_file
# ==== 超低延迟优化 (<25ms) ====
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_slow_start_after_idle = 0
EOF

  elif [ $latency -le 45 ]; then
    # 26-45ms: 低延迟优化
    echo "⚡ 应用 $proto 优化方案: 极速模式 (26-45ms)"
    cat <<EOF >> $config_file
# ==== 极速模式 (26-45ms) ====
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_slow_start_after_idle = 0
EOF

  elif [ $latency -le 85 ]; then
    # 46-85ms: 中低延迟优化
    echo "🔄 应用 $proto 优化方案: 均衡模式 (46-85ms)"
    cat <<EOF >> $config_file
# ==== 均衡模式 (46-85ms) ====
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
EOF

  elif [ $latency -le 120 ]; then
    # 86-120ms: 中延迟优化
    echo "🌐 应用 $proto 优化方案: 标准模式 (86-120ms)"
    cat <<EOF >> $config_file
# ==== 标准模式 (86-120ms) ====
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 1
EOF

  elif [ $latency -le 185 ]; then
    # 121-185ms: 中高延迟优化
    echo "⏱️ 应用 $proto 优化方案: 高延迟优化 (121-185ms)"
    cat <<EOF >> $config_file
# ==== 高延迟优化 (121-185ms) ====
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_slow_start_after_idle = 1
EOF

  elif [ $latency -le 200 ]; then
    # 186-200ms: 高延迟优化
    echo "📶 应用 $proto 优化方案: 超远距离模式 (186-200ms)"
    cat <<EOF >> $config_file
# ==== 超远距离模式 (186-200ms) ====
net.core.somaxconn = 2048
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_slow_start_after_idle = 1
EOF

  elif [ $latency -le 230 ]; then
    # 201-230ms: 超高延迟优化
    echo "🛰️ 应用 $proto 优化方案: 卫星链路优化 (201-230ms)"
    cat <<EOF >> $config_file
# ==== 卫星链路优化 (201-230ms) ====
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_slow_start_after_idle = 1
EOF

  else
    # >230ms: 极端延迟优化
    echo "🌍 应用 $proto 优化方案: 极端延迟优化 (>230ms)"
    cat <<EOF >> $config_file
# ==== 极端延迟优化 (>230ms) ====
net.core.somaxconn = 512
net.core.netdev_max_backlog = 512
net.ipv4.tcp_max_syn_backlog = 512
net.ipv4.tcp_slow_start_after_idle = 1
EOF
  fi

  # 应用配置
  sysctl -p $config_file >/dev/null 2>&1
  echo "📝 配置文件: $config_file"
}

# ========== 9. IPv6特殊优化 ==========
apply_ipv6_optimization() {
  local config_file="/etc/sysctl.d/99-ipv6-optimize.conf"
  
  # 清除旧配置
  rm -f $config_file
  
  cat <<EOF > $config_file
# ===== IPv6 特殊优化 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.proxy_ndp = 1
net.ipv6.conf.all.use_tempaddr = 0
EOF

  # 应用配置
  sysctl -p $config_file >/dev/null 2>&1
  echo "📝 IPv6优化配置文件: $config_file"
}

# ========== 10. 应用优化配置 ==========
# 应用IPv4优化
if [ -n "$IPV4_LATENCY" ]; then
  apply_latency_optimization $IPV4_LATENCY "ipv4"
fi

# 应用IPv6优化
if [ -n "$IPV6_LATENCY" ]; then
  apply_latency_optimization $IPV6_LATENCY "ipv6"
  # 应用IPv6特殊优化
  apply_ipv6_optimization
fi

# ========== 11. 智能管理 Swap ==========
echo -e "\n💾 检查Swap配置..."
existing_swap=$(free -m | awk '/Swap/{print $2}')
if [ "$existing_swap" -eq 0 ]; then
  echo "⚠️ 未检测到Swap，创建512MB Swap..."
elif [ "$existing_swap" -lt 256 ] || [ "$existing_swap" -gt 1024 ]; then
  echo "⚠️ 当前 Swap 大小 ${existing_swap}MB 不合理，重新创建 512MB Swap..."
else
  echo "✅ 当前Swap大小合理（${existing_swap}MB），无需调整"
fi

if [ "$existing_swap" -eq 0 ] || [ "$existing_swap" -lt 256 ] || [ "$existing_swap" -gt 1024 ]; then
  # 清理现有swap
  swapoff -a >/dev/null 2>&1 || true
  rm -f /swapfile >/dev/null 2>&1 || true
  
  # 创建新swap
  echo "🔄 创建Swap文件 (512MB)..."
  if ! command -v fallocate &> /dev/null || ! fallocate -l 512M /swapfile 2>/dev/null; then
    echo "⚠️ 使用dd创建swap文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  fi
  
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  
  # 永久生效
  if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  echo 'vm.swappiness = 10' >> /etc/sysctl.d/99-swap-optimize.conf
  sysctl -p /etc/sysctl.d/99-swap-optimize.conf >/dev/null
  echo "✅ Swap创建完成 (512MB)"
  echo "📝 Swap配置文件: /etc/fstab 和 /etc/sysctl.d/99-swap-optimize.conf"
fi

# ========== 12. 完成 ==========
echo -e "\n✅ 所有优化配置已完成"
echo "IPv4 延迟: ${IPV4_LATENCY}ms (优化方案已应用)"
echo "IPv6 延迟: ${IPV6_LATENCY}ms (优化方案已应用)"

if [ "$IS_XANMOD" -eq 0 ]; then
  echo -e "\n🔄 需要重启以启用新内核"
  read -p "是否现在重启? [Y/n] " ans
  if [[ "$ans" =~ ^[nN]$ ]]; then
    echo "请手动重启以完成优化"
    echo "⚠️ 注意: 新内核需要重启后才能生效"
  else
    echo "系统将在5秒后重启..."
    sleep 5
    reboot
  fi
else
  echo -e "\n✅ 所有优化已生效，当前运行内核: $(uname -r)"
  echo "使用以下命令验证:"
  echo "  sysctl net.ipv4.tcp_congestion_control"
  echo "  sysctl net.core.default_qdisc"
fi

echo "================================================================"
echo "🕒 脚本完成时间: $(date)"
echo "✅ 所有优化配置已完成"
echo "📝 详细日志请查看: $LOG_FILE"
echo "================================================================"

} | tee -a "$LOG_FILE" 2>&1

# 确保脚本退出时返回正确状态
exit 0
