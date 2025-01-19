#!/bin/bash
# IPv6 网络性能优化脚本
# 请以 root 用户运行

echo "开始优化IPv6网络参数..."

# 增大TCP读写缓冲区大小
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"

# 启用TCP BBR 拥塞控制算法
modprobe tcp_bbr
if ! grep -q "tcp_bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
  echo "TCP BBR未启用，请检查内核版本。"
else
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  echo "TCP BBR 拥塞控制算法已启用。"
fi

# 增加网络队列长度
sysctl -w net.core.netdev_max_backlog=250000

# 提高文件描述符限制
ulimit -n 1048576

# 调整IPv6相关参数
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.accept_ra=2
sysctl -w net.ipv6.conf.all.accept_ra=2

# 优化路径MTU发现
sysctl -w net.ipv4.tcp_mtu_probing=1

# 将以上配置永久生效
cat <<EOF >> /etc/sysctl.conf

# IPv6 网络优化配置
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=250000
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.all.accept_ra=2
EOF

echo "优化完成，重启网络服务以应用更改。"
