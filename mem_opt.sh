#!/bin/bash
# Ubuntu 内存优化一键脚本（带前后内存对比）
# 功能：卸载accounts-daemon + 释放缓存 + 精简服务 + 重置2G Swap + 内核调优
# 需 root 权限执行

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误]请使用 root 用户运行此脚本${NC}"
    exit 1
fi

echo -e "\n============================================="
echo -e "  Ubuntu 内存优化脚本 开始执行"
echo -e "============================================="

# ========== 1. 检测并卸载 accounts-daemon ==========
echo -e "\n----- 1. 检测 accounts-daemon 并处理 -----"
if dpkg -l | grep -q '^ii  accountsservice'; then
    echo "检测到 accountsservice（accounts-daemon），正在卸载..."
    apt remove --purge -y accountsservice > /dev/null 2>&1
    apt autoremove -y > /dev/null 2>&1
    echo -e "${GREEN}✅ accounts-daemon 已卸载${NC}"
else
    echo -e "${YELLOW}⚠️ 未安装 accounts-daemon，跳过${NC}"
fi

# ========== 记录优化前内存空闲情况（释放缓存前） ==========
echo -e "\n----- 记录优化前内存状态 -----"
MEM_BEFORE_AVAIL=$(free -h | awk '/^Mem/{print $7}')
MEM_BEFORE_FREE=$(free -h | awk '/^Mem/{print $4}')
MEM_BEFORE_USED=$(free -h | awk '/^Mem/{print $3}')
echo -e "优化前 - 已用: ${MEM_BEFORE_USED} | 空闲: ${MEM_BEFORE_FREE} | 可用: ${MEM_BEFORE_AVAIL}"

# ========== 2. 临时释放内存缓存 ==========
echo -e "\n----- 2. 临时释放内存缓存 -----"
sync && echo 3 > /proc/sys/vm/drop_caches
echo -e "${GREEN}✅ 已释放页面缓存、目录项与 inode 缓存${NC}"

# ========== 3. 精简后台服务，永久降低常驻内存 ==========
echo -e "\n----- 3. 精简后台服务 -----"
# 待禁用服务列表
DISABLE_SVC=(
    "bluetooth.service"
    "cups.service"
    "cups-browsed.service"
    "avahi-daemon.service"
    "ModemManager.service"
    "unattended-upgrades.service"
)

for svc in "${DISABLE_SVC[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc"; then
        systemctl disable --now "$svc" > /dev/null 2>&1
        echo "已禁用服务：$svc"
    else
        echo "未安装，跳过：$svc"
    fi
done

# 优化 journald 内存占用
echo -e "\n优化 systemd-journald 配置..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-memlimit.conf <<EOF
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=30M
ForwardToSyslog=no
EOF
systemctl restart systemd-journald
echo -e "${GREEN}✅ 后台服务精简完成${NC}"

# ========== 4. 重置 2G Swap 交换分区 ==========
echo -e "\n----- 4. 重置 2GB Swap 交换分区 -----"
# 关闭所有现有 swap
swapoff -a > /dev/null 2>&1

# 删除旧 swap 文件
if [ -f /swapfile ]; then
    rm -f /swapfile
    echo "已删除旧的 swapfile"
fi

# 清理 fstab 中旧的 swap 条目
sed -i '/\/swapfile.*swap/d' /etc/fstab

# 创建新的 2G swap
echo "正在创建 2GB 交换文件..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile > /dev/null 2>&1
swapon /swapfile

# 写入 fstab 开机自动挂载
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo -e "${GREEN}✅ 2GB Swap 重置完成${NC}"

# ========== 5. 内核内存参数永久调优 ==========
echo -e "\n----- 5. 内核内存参数永久调优 -----"
# 先删除已有的重复参数
sed -i '/^vm.swappiness/d' /etc/sysctl.conf
sed -i '/^vm.vfs_cache_pressure/d' /etc/sysctl.conf
sed -i '/^vm.dirty_ratio/d' /etc/sysctl.conf
sed -i '/^vm.dirty_background_ratio/d' /etc/sysctl.conf
sed -i '/^vm.min_free_kbytes/d' /etc/sysctl.conf

# 追加优化参数
cat >> /etc/sysctl.conf <<EOF

# 内存优化参数
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 8192
EOF

# 立即生效
sysctl -p > /dev/null 2>&1
echo -e "${GREEN}✅ 内核参数已应用并永久生效${NC}"

# ========== 记录优化后内存情况并输出对比 ==========
echo -e "\n============================================="
echo -e "  内存优化前后对比"
echo -e "============================================="
MEM_AFTER_AVAIL=$(free -h | awk '/^Mem/{print $7}')
MEM_AFTER_FREE=$(free -h | awk '/^Mem/{print $4}')
MEM_AFTER_USED=$(free -h | awk '/^Mem/{print $3}')
SWAP_AFTER_TOTAL=$(free -h | awk '/^Swap/{print $2}')

echo -e "${CYAN}项目          优化前          优化后${NC}"
echo -e "已用内存      ${MEM_BEFORE_USED}          ${MEM_AFTER_USED}"
echo -e "纯空闲内存    ${MEM_BEFORE_FREE}          ${MEM_AFTER_FREE}"
echo -e "可用内存      ${MEM_BEFORE_AVAIL}          ${MEM_AFTER_AVAIL}"
echo -e "Swap 总量     -               ${SWAP_AFTER_TOTAL}"

echo -e "\n${GREEN}✅ 全部优化执行完成${NC}"
echo -e "${YELLOW}💡 建议重启系统，确保所有服务配置完全生效${NC}"
