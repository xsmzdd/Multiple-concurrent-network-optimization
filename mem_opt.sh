#!/bin/bash
# Multiple-concurrent network & memory optimize
# Auto detect NIC / Auto calc tcp_mem / Swap conditional(Disk free >=5G) / Disable unattended-upgrades

set -euo pipefail

# ===================== 1. 关闭 unattended-upgrades，杀掉占用进程 =====================
echo -e "\n===== Step1: Stop unattended-upgrades auto update ====="
# 杀死正在运行的unattended-upgr进程
if pgrep -f unattended-upgr > /dev/null;then
    pkill -9 -f unattended-upgr
    echo ">> unattended-upgr process killed"
fi
# 关闭开机自启
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
echo ">> unattended-upgrades disabled, will not auto start after reboot"

# ===================== 2. 自动获取活跃网卡名称 =====================
NIC=$(ip -br link | awk '$2=="UP" && $1!~/lo/{print $1;exit}')
if [ -z "${NIC}" ];then
    echo "ERROR: Can not detect active network card!"
    exit 1
fi
echo -e "\n===== Step2: Detected active NIC: ${NIC} ====="

# ===================== 3. 获取系统总内存，动态计算tcp_mem =====================
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_TOTAL_GB=$(( MEM_TOTAL_MB / 1024 ))
echo "Total Memory: ${MEM_TOTAL_MB} MB (${MEM_TOTAL_GB} GB)"

# tcp_mem 计算公式： page size=4KB，单位是内存页
PAGE_SIZE=4
tcp_low=$(( MEM_TOTAL_KB * 10 / 100 / PAGE_SIZE ))
tcp_press=$(( MEM_TOTAL_KB * 20 / 100 / PAGE_SIZE ))
tcp_high=$(( MEM_TOTAL_KB * 40 / 100 / PAGE_SIZE ))
echo "Calculated tcp_mem: ${tcp_low} ${tcp_press} ${tcp_high}"

# ===================== 4. sysctl.conf 网络高并发参数 =====================
SYSCTL_FILE="/etc/sysctl.conf"
cp ${SYSCTL_FILE} ${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)
echo -e "\n===== Step3: Write sysctl network params ====="

cat >> ${SYSCTL_FILE} <<EOF
# ===== Auto Network Optimize Start =====
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_mem = ${tcp_low} ${tcp_press} ${tcp_high}
net.ipv4.tcp_wmem = 4096 16384 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 131072
# ===== Auto Network Optimize End =====
EOF

sysctl -p
echo "sysctl reload done"

# ===================== 5. Systemd service for txqueuelen =====================
echo -e "\n===== Step4: Create txqueuelen systemd service for ${NIC} ====="
cat > /etc/systemd/system/txqueuelen-set.service <<EOF
[Unit]
Description=Set txqueuelen for ${NIC}
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set dev ${NIC} txqueuelen 10000
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable txqueuelen-set.service
systemctl start txqueuelen-set.service
echo "txqueuelen service installed, current qlen:"
ip link show ${NIC} | grep qlen

# ===================== 6. Swap条件配置：根分区可用磁盘 >=5GB 才创建swap =====================
echo -e "\n===== Step5: Disk free check for swap ====="
# 获取 / 分区可用空间(单位KB)
DISK_FREE_KB=$(df -P / | awk 'NR==2 {print $4}')
DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
echo "Root partition / free space: ${DISK_FREE_GB} GB"

if [ ${DISK_FREE_GB} -ge 5 ];then
    echo "Disk free >=5G, start setup swap"
    # 判断swap是否已经存在
    if [ $(swapon --show | wc -l) -gt 1 ];then
        echo "Swap already exists, skip swap create"
    else
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    # 设置swappiness
    echo "vm.swappiness=10" >> ${SYSCTL_FILE}
    sysctl -p
else
    echo "Disk free <5G (${DISK_FREE_GB}G), skip swap configuration."
fi

echo -e "\n===== All optimize finished! ====="
echo "==== Verify Commands ====="
echo "ip link show ${NIC}"
echo "sysctl net.ipv4.tcp_mem net.ipv4.tcp_congestion_control net.ipv4.ip_local_port_range"
echo "free -h"
echo "df -h /"
