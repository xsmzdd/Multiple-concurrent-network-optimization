#!/bin/bash

# 打开文件描述符限制 将硬限制和软限制都设置为65535，以允许更多的文件描述符
echo "* hard nofile 65535" >> /etc/security/limits.conf 
echo "* soft nofile 65535" >> /etc/security/limits.conf

# 调整内核参数 通过 here 文档（heredoc）向 /etc/sysctl.conf 文件中添加内核参数
cat << EOF >> /etc/sysctl.conf
# 调整网络参数 增加 TCP 最大连接数
net.core.somaxconn = 65535
# 增加网络设备的最大排队长度
net.core.netdev_max_backlog = 65535
# 增大接收缓冲区和发送缓冲区的大小
net.core.rmem_max = 16777216 
net.core.wmem_max = 16777216
# 增加 TCP 最大半连接队列长度
net.ipv4.tcp_max_syn_backlog = 65535
# 增加 TIME-WAIT 状态的最大数量
net.ipv4.tcp_max_tw_buckets = 65535
# 允许 TIME-WAIT 状态的 socket 重新用于新的 TCP 连接
net.ipv4.tcp_tw_reuse = 1
# 减少 TIME-WAIT 状态的超时时间
net.ipv4.tcp_fin_timeout = 10
# 禁用 TCP 连接的慢启动算法
net.ipv4.tcp_slow_start_after_idle = 0
# 设置 TCP Keepalive 的时间间隔和尝试次数
net.ipv4.tcp_keepalive_time = 300 
net.ipv4.tcp_keepalive_probes = 5 
net.ipv4.tcp_keepalive_intvl = 15
# 开启 SYN Cookie 机制以防止 SYN 攻击
net.ipv4.tcp_syncookies = 1
# 开启 TCP 时间戳选项以提高性能
net.ipv4.tcp_timestamps = 1
# 开启 TCP 窗口缩放选项以提高性能
net.ipv4.tcp_window_scaling = 1
# 设置 TCP 接收窗口广告窗口大小
net.ipv4.tcp_rmem = 4096 87380 16777216
# 减少 TCP 性能峰值
net.ipv4.tcp_limit_output_bytes = 131072
# 修改系统 initcwnd 参数
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
# 修改系统的 Ring Buffer 大小和队列数量
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536
net.core.netdev_budget = 300
# 增加 txqueuelen 参数
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_mtu_probing = 1
# 检查系统虚拟化，如果系统虚拟化为 KVM，则关闭 TSO 和 GSO
if [ "$(cat /sys/class/net/eth0/device/uevent | grep ^DRIVER | awk -F '=' '{print $2}')" == "virtio_net" ]; then
    ethtool -K eth0 tso off gso off
fi

EOF

# 应用新的内核参数 使用 sysctl 命令重新加载 /etc/sysctl.conf 文件中的配置
sysctl -p

kernel_version=$(uname -r)
echo "当前内核版本为: $kernel_version"

# 检查是否已经安装了 BBR 模块
if lsmod | grep -q "^tcp_bbr "; then
    echo "BBR 模块已安装"
else
    # 安装 BBR 模块
    echo "安装 BBR 模块..."
    sudo modprobe tcp_bbr
    echo "tcp_bbr" | sudo tee -a /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
fi

# 验证 BBR 是否已启用
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "BBR 已启用"
else
    echo "BBR 启用失败，请手动检查您的系统设置"
fi

echo "系统优化设置完成。"
