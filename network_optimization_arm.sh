#!/bin/bash

# --- 1. 提升TCP性能 ---
echo "提升TCP性能..."

# 调整TCP缓冲区大小
echo "net.ipv4.tcp_rmem = 4096 87380 6291456" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 6291456" >> /etc/sysctl.conf

# 增加TCP窗口大小
echo "net.ipv4.tcp_window_scaling = 1" >> /etc/sysctl.conf
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf

# 启用TCP快速打开 (TCP Fast Open)
echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf

# 启用BBR拥塞控制算法
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

# 应用sysctl配置
sysctl -p

# --- 2. 优化UDP性能 ---
echo "优化UDP性能..."

# 增加UDP接收和发送缓冲区
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.rmem_default = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_default = 16777216" >> /etc/sysctl.conf

# 调整最大UDP数据包大小
echo "net.ipv4.udp_rmem_min = 16384" >> /etc/sysctl.conf
echo "net.ipv4.udp_wmem_min = 16384" >> /etc/sysctl.conf

# --- 3. 启用IPv6优化 ---
echo "启用IPv6优化..."

# 增加IPv6 MTU大小
echo "net.ipv6.conf.all.mtu = 1500" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.mtu = 1500" >> /etc/sysctl.conf

# 启用IPv6流量工程
echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf

# 应用sysctl配置
sysctl -p

# --- 4. 提高系统性能 ---
echo "提高系统性能..."

# 启用大页面内存
echo "vm.nr_hugepages = 128" >> /etc/sysctl.conf

# 提升网络吞吐量
echo "net.core.netdev_max_backlog = 5000" >> /etc/sysctl.conf
echo "net.core.somaxconn = 4096" >> /etc/sysctl.conf

# 增加最大文件描述符数
echo "fs.file-max = 1000000" >> /etc/sysctl.conf
echo "ulimit -n 1000000" >> /etc/security/limits.conf

# --- 5. 重启网络服务 ---
echo "重启网络服务以应用优化..."

# 重启网络服务
systemctl restart networking

# --- 6. 提示完成 ---
echo "网络优化已完成，建议重新启动服务器以确保所有配置生效。"
