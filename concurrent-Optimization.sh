#!/bin/bash
# Network optimize script for专线VPS, Debian12 cloud-init, high concurrent multi connections
# Auto detect NIC + Auto detect RAM and dynamic calculate tcp_mem
# Must run as root
set -e

echo "====================================="
echo "      Start VPS Network Optimization (Auto NIC + Auto RAM)"
echo "====================================="

# ========== 1.自动检测业务网卡，跳过lo回环网卡 ==========
NIC=$(ip -br link show | awk '$1!="lo" && $2~/UP/{print $1;exit}')
if [ -z "${NIC}" ];then
    echo "ERROR: Cannot detect active network card!"
    exit 1
fi
echo "✅ Detected active network interface: ${NIC}"

# ========== 2.自动读取内存，动态计算 tcp_mem（单位：4KB页面） ==========
# 获取MemAvailable(KB)
MEM_AVAIL_KB=$(cat /proc/meminfo | grep MemAvailable | awk '{print $2}')
# TCP最多占用可用内存的45%，留给业务程序预留内存
TCP_MAX_KB=$(( MEM_AVAIL_KB * 45 / 100 ))
# 转换为 4k页面数量：pages = KB /4
TCP_MAX_PAGE=$(( TCP_MAX_KB / 4 ))
TCP_LOW=$(( TCP_MAX_PAGE * 50 / 100 ))
TCP_PRESS=$(( TCP_MAX_PAGE * 75 / 100 ))
TCP_PANIC=${TCP_MAX_PAGE}

echo "✅ Detected MemAvailable: ${MEM_AVAIL_KB} KB"
echo "✅ Calculated tcp_mem (page): $TCP_LOW $TCP_PRESS $TCP_PANIC"

# 1. Install ethtool
echo "[1/4] Install ethtool ..."
apt update -qq
apt install -y ethtool

# 2. Create systemd service for txqueuelen (auto inject NIC name)
echo "[2/4] Create txqueuelen-${NIC}.service ..."
cat > /etc/systemd/system/txqueuelen-${NIC}.service <<EOF
[Unit]
Description=Set txqueuelen for ${NIC}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set dev ${NIC} txqueuelen 10000
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable txqueuelen-${NIC}.service
systemctl start txqueuelen-${NIC}.service

# 3. Backup sysctl and append optimized TCP config
echo "[3/4] Write sysctl.conf TCP parameters ..."
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S)
cat >> /etc/sysctl.conf <<EOT
# ==============================================
# TCP High Concurrency Optimize for Private Line VPS
# Match iperf best buffer:4MiB, BBR
# Auto generate tcp_mem by available memory
# ==============================================
net.ipv4.tcp_wmem = 4096    65536   4194304
net.ipv4.tcp_rmem = 4096    87380   4194304

# Global socket buffer limit
net.core.wmem_max = 8388608
net.core.rmem_max = 8388608
net.core.wmem_default = 262144
net.core.rmem_default = 262144

# BBR tune
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 131072

# TIME_WAIT recycle
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# SYN protect
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 10
net.ipv4.tcp_keepalive_intvl = 2
net.ipv4.tcp_keepalive_probes = 3

# TCP basic option for long haul private line
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1

# Dynamic calculated tcp_mem (pages of 4KB)
net.ipv4.tcp_mem = ${TCP_LOW} ${TCP_PRESS} ${TCP_PANIC}
EOT

# Reload sysctl
sysctl -p

echo "[4/4] Optimization finished! "
echo "====================================="
echo "====== Post-check commands after reboot ====="
echo "ip link show ${NIC}"
echo "sysctl net.ipv4.tcp_wmem"
echo "sysctl net.ipv4.tcp_mem"
echo "systemctl status txqueuelen-${NIC}.service"
echo "====================================="
echo "Detected NIC: ${NIC}"
echo "Calculated tcp_mem: $TCP_LOW $TCP_PRESS $TCP_PANIC"
echo "Tips: Reboot server to verify persistence!"
