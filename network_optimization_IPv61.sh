#!/bin/bash
# IPv6 网络性能优化脚本
# 请以 root 用户运行

echo "开始优化IPv6网络参数..."

# 增大TCP读写缓冲区大小
echo "增大TCP读写缓冲区大小..."
sysctl -w net.core.rmem_max=268435456
sysctl -w net.core.wmem_max=268435456
sysctl -w net.ipv4.tcp_rmem="4096 87380 268435456"
sysctl -w net.ipv4.tcp_wmem="4096 65536 268435456"

# 启用TCP BBR 拥塞控制算法
echo "启用TCP BBR拥塞控制算法..."
modprobe tcp_bbr
if ! grep -q "tcp_bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
  echo "TCP BBR未启用，请检查内核版本。"
else
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  sysctl -w net.core.default_qdisc=fq
  sysctl -w net.ipv4.tcp_bbr_cwnd_gain=3
  echo "TCP BBR 拥塞控制算法已启用。"
fi

# 增加网络队列长度
echo "增加网络队列长度..."
sysctl -w net.core.netdev_max_backlog=500000
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535

# 优化TCP重传和超时参数
echo "优化TCP重传和超时参数..."
sysctl -w net.ipv4.tcp_retries2=8
sysctl -w net.ipv4.tcp_retries1=3
sysctl -w net.ipv4.tcp_syn_retries=3
sysctl -w net.ipv4.tcp_synack_retries=3

# 启用TCP时间戳和选择性确认
echo "启用TCP时间戳和选择性确认..."
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1
sysctl -w net.ipv4.tcp_dsack=1

# 优化路径MTU发现
echo "优化路径MTU发现..."
sysctl -w net.ipv4.tcp_mtu_probing=1

# 优化IPv6相关参数
echo "优化IPv6相关参数..."
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.accept_ra=2
sysctl -w net.ipv6.conf.all.accept_ra=2
sysctl -w net.ipv6.conf.all.mtu=1500
sysctl -w net.ipv6.conf.default.mtu=1500
sysctl -w net.ipv6.route.mtu_expires=600
sysctl -w net.ipv6.route.min_adv_mss=1220

# 提高文件描述符限制
echo "提高文件描述符限制..."
ulimit -n 1048576
echo "fs.file-max=1048576" >> /etc/sysctl.conf

# 将以上配置永久生效
echo "将配置写入/etc/sysctl.conf..."
cat <<EOF >> /etc/sysctl.conf

# IPv6 网络优化配置
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=4096 87380 268435456
net.ipv4.tcp_wmem=4096 65536 268435456
net.core.netdev_max_backlog=500000
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_retries2=8
net.ipv4.tcp_retries1=3
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.all.mtu=1500
net.ipv6.conf.default.mtu=1500
net.ipv6.route.mtu_expires=600
net.ipv6.route.min_adv_mss=1220
fs.file-max=1048576
EOF

# 重新加载sysctl配置
echo "重新加载sysctl配置..."
sysctl -p

echo "优化完成，请重启网络服务以应用更改。"