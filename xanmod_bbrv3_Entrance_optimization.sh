#!/bin/bash
set -e

echo -e "\n🚀 开始：XanMod + BBRv3 + 高性能网络优化一键脚本（IPv4/IPv6 自动识别）\n"
echo -e "📅 系统信息: $(lsb_release -ds) | 内核: $(uname -r) | 处理器: $(nproc)核 | 内存: $(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')MB\n"

# ========== 网络环境检测 ==========
echo "🌐 正在检测IPv6网络可用性..."
if ping6 -c1 -w1 ipv6.google.com &>/dev/null; then
  USE_IPV6=true
  CURL_IP="-6"
  APT_OPTS="-o Acquire::ForceIPv6=true"
  echo "✅ 检测到可用的 IPv6 网络"
else
  USE_IPV6=false
  CURL_IP=""
  APT_OPTS=""
  echo "⚠️ 未检测到 IPv6，将使用 IPv4 网络"
fi

# ========== 0. 安装依赖 ==========
echo -e "\n🔍 检查并安装必要依赖..."
apt update $APT_OPTS >/dev/null 2>&1

MINIMAL_PKGS=("curl" "wget" "gpg" "dirmngr" "iproute2" "ca-certificates")
MISSING_PKGS=()

for pkg in "${MINIMAL_PKGS[@]}"; do
    if ! dpkg -l | grep -q " $pkg "; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "📦 安装依赖: ${MISSING_PKGS[*]}"
    apt install -y --no-install-recommends "${MISSING_PKGS[@]}"
else
    echo "✅ 所有依赖已安装"
fi

# ========== 1. 检查内核 ==========
KERNEL_VERSION="6.15.3-x64v3-xanmod1"
echo -e "\n🔎 检测当前内核版本..."
CURRENT_KERNEL=$(uname -r)
echo "  当前内核: $CURRENT_KERNEL"
echo "  目标内核: $KERNEL_VERSION"

if [[ "$CURRENT_KERNEL" == *"$KERNEL_VERSION"* ]]; then
    echo "✅ 已运行目标内核"
    IS_XANMOD=1
else
    echo "⚠️ 未运行目标内核，需要安装"
    IS_XANMOD=0
fi

# ========== 2. 备份 sysctl ==========
BACKUP_FILE="/etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/sysctl.conf "$BACKUP_FILE"
echo "✅ sysctl 配置已备份: $BACKUP_FILE"

# ========== 3. 安装 XanMod ==========
if [ "$IS_XANMOD" -eq 0 ]; then
  echo -e "\n📥 开始安装 XanMod 内核 $KERNEL_VERSION..."

  if [ ! -f "/etc/apt/sources.list.d/xanmod-kernel.list" ]; then
    echo "🔗 添加 XanMod 仓库..."
    echo 'deb [arch=amd64] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-kernel.list

    echo "🔑 下载 GPG 密钥..."
    if curl $CURL_IP --fail --retry 3 --retry-delay 2 https://dl.xanmod.org/gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/xanmod.gpg; then
      echo "✅ GPG 密钥导入完成"
    else
      echo "❌ GPG 密钥导入失败，请检查网络或更换源"
      exit 1
    fi
  fi

  echo "🔄 更新源..."
  apt update $APT_OPTS >/dev/null

  echo "⬇️ 安装内核..."
  if apt install -y --no-install-recommends linux-image-$KERNEL_VERSION; then
    echo "✅ 内核安装成功"
  else
    echo "❌ 内核安装失败，尝试下载 DEB 包..."
    if apt download linux-image-$KERNEL_VERSION && dpkg -i linux-image-*.deb; then
      echo "✅ DEB 安装成功"
      rm -f linux-image-*.deb
    else
      echo "❌ DEB 安装也失败，终止执行"
      exit 1
    fi
  fi

  echo "📌 设置默认启动新内核..."
  grub-set-default 0 || echo "⚠️ grub-set-default 命令未找到"
fi

# ========== 4. 网络优化参数 ==========
echo -e "\n📝 写入网络优化 sysctl 参数..."

sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf

## ==== 网络优化设置 ====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
EOF

# ========== 5. 内存判断动态参数 ==========
MEM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
if [ "$MEM_MB" -le 1024 ]; then
  TCP_MEM="393216 524288 786432"
  TCP_RMEM="4096 87380 262144"
  TCP_WMEM="4096 65536 262144"
elif [ "$MEM_MB" -le 8192 ]; then
  TCP_MEM="1572864 2097152 3145728"
  TCP_RMEM="32768 131072 16777216"
  TCP_WMEM="8192 131072 16777216"
else
  TCP_MEM="3145728 4194304 6291456"
  TCP_RMEM="65536 262144 33554432"
  TCP_WMEM="65536 262144 33554432"
fi

sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_.*/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf

# ==== 高并发 TCP 设置 ====
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_max_orphans = 16384
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.ip_local_port_range = 1024 65535
EOF

echo "✅ TCP 优化参数已配置"

# ========== 6. IPv6 优化（仅在可用时） ==========
if [ "$USE_IPV6" == true ]; then
  echo "🔧 写入 IPv6 优化参数..."
  sed -i '/net.ipv6.conf./d' /etc/sysctl.conf

  cat <<EOF >> /etc/sysctl.conf

## ==== IPv6 优化 ====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.ip_nonlocal_bind = 1
net.ipv6.route.gc_timeout = 60
EOF
  echo "✅ IPv6 优化完成"
else
  echo "ℹ️ 跳过 IPv6 优化（未检测到 IPv6）"
fi

# ========== 7. Swap 设置 ==========
SWAP_MB=$(free -m | awk '/Swap/{print $2}')
if [ "$SWAP_MB" -eq 0 ] || [ "$SWAP_MB" -lt 256 ] || [ "$SWAP_MB" -gt 1024 ]; then
  echo "🔄 创建 512MB Swap..."
  swapoff -a || true
  rm -f /swapfile
  dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness = 10' >> /etc/sysctl.conf
  echo "✅ Swap 创建完成"
else
  echo "✅ 当前 Swap 正常 (${SWAP_MB}MB)"
fi

# ========== 8. 应用配置 ==========
echo -e "\n⚙️ 应用 sysctl 配置..."
sysctl -p >/dev/null 2>&1 || true

# ========== 9. 完成 ==========
if [ "$IS_XANMOD" -eq 0 ]; then
  echo -e "\n✅ 配置完成，请重启以启用新内核和设置"
  read -p "🔁 是否立即重启？[Y/n] " ans
  [[ "$ans" != "n" && "$ans" != "N" ]] && reboot
else
  echo -e "\n✅ 优化已完成，当前运行 XanMod $KERNEL_VERSION"
  echo -e "📊 状态检查："
  echo -e "  ➤ 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo -e "  ➤ 队列规则: $(sysctl -n net.core.default_qdisc)"
  echo -e "  ➤ Swap: $(free -m | awk '/Swap/{print $2}')MB"
fi

echo -e "\n✨ 优化脚本执行完成！\n"
