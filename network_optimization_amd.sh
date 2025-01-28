#!/bin/bash

# 检查是否以 root 身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 身份运行此脚本。"
    exit 1
fi

echo "开始优化网络参数（适用于 Debian/Ubuntu amd64 系统）..."

# 修改 sysctl.conf 配置
echo "备份 /etc/sysctl.conf 文件..."
cp /etc/sysctl.conf /etc/sysctl.conf.bak

echo "应用网络优化配置..."
cat <<EOF >> /etc/sysctl.conf

# 网络优化参数
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_congestion_control = bbr

# IPv6 优化
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1

# UDP 优化
net.core.optmem_max = 25165824
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 其他优化
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
EOF

# 应用 sysctl 配置
echo "加载优化后的 sysctl 配置..."
sysctl -p

# 启用 BBR 拥塞控制算法
echo "启用 BBR 拥塞控制算法..."
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
sysctl -p

# 检查 BBR 是否启用
echo "验证 BBR 状态..."
sysctl net.ipv4.tcp_congestion_control
lsmod | grep bbr

# 安装 ethtool（如果未安装）
if ! command -v ethtool &> /dev/null; then
    echo "安装 ethtool 工具..."
    apt update && apt install -y ethtool
fi

# 调整网络接口队列（适配多核 x86 架构）
echo "优化网络接口队列..."
for iface in $(ls /sys/class/net/ | grep -v lo); do
    if ethtool -G $iface rx 4096 tx 4096 &> /dev/null; then
        echo "已优化 $iface 队列参数"
    else
        echo "注意：$iface 队列参数调整失败（请检查驱动支持）"
    fi
    
    # 启用多队列（如果支持）
    if ethtool -L $iface combined 4 &> /dev/null; then
        echo "已启用 $iface 多队列"
    fi
done

# 启用 irqbalance 服务
echo "检查并优化中断请求分配..."
if ! command -v irqbalance &> /dev/null; then
    apt install -y irqbalance
fi

# 针对多核 CPU 优化配置
sed -i 's/^#ONESHOT=.*/ONESHOT=no/' /etc/default/irqbalance
systemctl restart irqbalance

# 优化完成
echo "网络优化已完成！"

# 提示用户是否需要重启
read -p "部分优化需要重启生效，是否立即重启？ (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    echo "系统即将重启..."
    reboot
else
    echo "请稍后手动重启以应用完整优化！"
fi
