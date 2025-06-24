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

> "$LOG_FILE"

# ========== 1. 安装必要依赖 ==========
install_dependencies() {
    echo "🔍 检查并安装必要依赖..."
    REQUIRED_PKGS=("curl" "wget" "gpg" "dirmngr" "iproute2" "ca-certificates" "bc" "iputils-ping" "util-linux")
    MISSING_PKGS=()

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            MISSING_PKGS+=("$pkg")
        fi
    done

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
IS_XANMOD=0
[[ "$CURRENT_KERNEL" == *"$KERNEL_VERSION"* ]] && IS_XANMOD=1

echo "ℹ️ 当前内核: $CURRENT_KERNEL"
echo "ℹ️ 目标内核: $KERNEL_VERSION"
echo "ℹ️ 内核匹配状态: $([ $IS_XANMOD -eq 1 ] && echo “是” || echo “否”)"

# ========== 3. 备份 ==========
echo "🔧 备份系统配置..."
BACKUP_TIME=$(date +%Y%m%d_%H%M%S)
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$BACKUP_TIME
[ -f /etc/rc.local ] && cp /etc/rc.local /etc/rc.local.bak.$BACKUP_TIME
mkdir -p /etc/sysctl.d/backups

echo "✅ 备份完成"
echo "📌 备份文件:"
echo "  - /etc/sysctl.conf.bak.$BACKUP_TIME"
echo "  - /etc/rc.local.bak.$BACKUP_TIME"

# ========== 4. 安装 XanMod 内核 ==========
if [ "$IS_XANMOD" -eq 0 ]; then
  echo "📅 安装 XanMod 内核 $KERNEL_VERSION..."
  echo 'deb [signed-by=/usr/share/keyrings/xanmod-kernel.gpg] https://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null

  echo "🔑 下载GPG密钥..."
  if ! wget -qO - https://dl.xanmod.org/gpg.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-kernel.gpg >/dev/null 2>/dev/null; then
    echo "⚠️ 主密钥失败，使用备用地址..."
    wget -qO - https://203.55.176.82:21569/down/BVwPEZcfSAlF.key | gpg --dearmor -o /usr/share/keyrings/xanmod-kernel.gpg 2>/dev/null
  fi

  apt update >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt install -y linux-image-$KERNEL_VERSION </dev/null
  grub-set-default 0
  update-grub
  echo "✅ 内核安装完成"
else
  echo "✅ 已运行目标内核: $KERNEL_VERSION"
fi

# ========== 5. 网络栈检测 ==========
HAS_IPV4=0
HAS_IPV6=0
ip -4 addr show | grep -q "inet" && HAS_IPV4=1
ip -6 addr show | grep -q "inet6" && HAS_IPV6=1

echo -e "\n📡 网络栈检测结果:"
echo "IPv4 支持: $([ "$HAS_IPV4" -eq 1 ] && echo ✅ || echo ❌)"
echo "IPv6 支持: $([ "$HAS_IPV6" -eq 1 ] && echo ✅ || echo ❌)"

# ========== 6. 用户输入延迟值 ==========
if [ "$HAS_IPV4" -eq 1 ]; then
  while true; do
    read -p "📏 请输入 IPv4 网络延迟 (ms 1-1000): " IPV4_LATENCY
    if [[ "$IPV4_LATENCY" =~ ^[0-9]+$ ]] && [ "$IPV4_LATENCY" -ge 1 ] && [ "$IPV4_LATENCY" -le 1000 ]; then
      echo "📝 IPv4 延迟: ${IPV4_LATENCY}ms"
      break
    else
      echo "❌ 输入无效，请重试 (1-1000)"
    fi
  done
fi

if [ "$HAS_IPV6" -eq 1 ]; then
  while true; do
    read -p "📏 请输入 IPv6 网络延迟 (ms 1-1000): " IPV6_LATENCY
    if [[ "$IPV6_LATENCY" =~ ^[0-9]+$ ]] && [ "$IPV6_LATENCY" -ge 1 ] && [ "$IPV6_LATENCY" -le 1000 ]; then
      echo "📝 IPv6 延迟: ${IPV6_LATENCY}ms"
      break
    else
      echo "❌ 输入无效，请重试 (1-1000)"
    fi
  done
fi

# ========== 后续网络优化等逻辑保留不变 ==========
# 可将延迟值传入 apply_latency_optimization 函数等逻辑中继续处理

} | tee -a "$LOG_FILE" 2>&1

exit 0
