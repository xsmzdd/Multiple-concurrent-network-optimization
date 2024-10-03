#!/bin/bash

# 更新系统
apt update && apt upgrade -y

# 检测是否安装iptables，如果没有则安装
if ! command -v iptables &> /dev/null; then
    echo "安装 iptables..."
    apt install -y iptables
fi

# 检测是否安装ifb模块，必要时加载
if ! lsmod | grep -q ifb; then
    echo "加载ifb模块..."
    modprobe ifb
fi

# 获取所有网络接口的名称
interfaces=$(nmcli device status | awk '{print $1}' | grep -v DEVICE)

# 循环遍历每个网络接口
for interface in $interfaces; do
    # 使用nmcli增加环缓冲的大小
    echo "Setting ring buffer size for interface $interface..."
    sudo nmcli connection modify $interface txqueuelen 10000

    # 调优网络设备积压队列以避免数据包丢弃
    echo "Tuning network device backlog for interface $interface..."
    sudo nmcli connection modify $interface rxqueuelen 10000

    # 增加NIC的传输队列长度
    echo "Increasing NIC transmission queue length for interface $interface..."
    sudo nmcli connection modify $interface transmit-hash-policy layer2+3
done

# 备份原始配置文件
if [ ! -f /etc/sysctl.conf.bak ]; then
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
fi

# 配置内核参数
cat << EOF > /etc/sysctl.conf
# 网络调优: 基本
net.ipv4.tcp_timestamps=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2

# 网络调优: 内核 Backlog 队列和缓存相关
net.core.wmem_default=16384
net.core.rmem_default=262144
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=4096 16384 536870912
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_collapse_max_bytes=6291456
net.ipv4.tcp_notsent_lowat=131072
net.core.netdev_max_backlog=10240
net.ipv4.tcp_max_syn_backlog=10240
net.core.somaxconn=8192
net.ipv4.tcp_abort_on_overflow=1
net.core.default_qdisc=fq
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_slow_start_after_idle=0

# 网络调优: 其他
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_syncookies=0
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_no_metrics_save=1
net.unix.max_dgram_qlen=1024
net.ipv4.route.gc_timeout=100
net.ipv4.tcp_mtu_probing=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_intvl=2
net.ipv4.tcp_max_orphans=262144
net.ipv4.neigh.default.gc_thresh1=128
net.ipv4.neigh.default.gc_thresh2=512
net.ipv4.neigh.default.gc_thresh3=4096
net.ipv4.neigh.default.gc_stale_time=120
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2

# IPv6 调优
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv6.conf.all.accept_dad=1
net.ipv6.conf.default.accept_dad=1
net.ipv6.conf.all.accept_ra=1
net.ipv6.conf.default.accept_ra=1
net.ipv6.conf.all.router_solicitations=1
net.ipv6.conf.default.router_solicitations=1
net.ipv6.conf.all.max_addresses=16
net.ipv6.conf.default.max_addresses=16

# 内核调优
kernel.panic=1
kernel.pid_max=32768
kernel.shmmax=4294967296
kernel.shmall=1073741824
kernel.core_pattern=core_%e
vm.panic_on_oom=1
vm.vfs_cache_pressure=250
vm.swappiness=10
vm.dirty_ratio=10
vm.overcommit_memory=1
fs.file-max=1048575
fs.inotify.max_user_instances=8192
kernel.sysrq=1
vm.zone_reclaim_mode=0
EOF

# 应用新的内核参数
sysctl -p

# 更新 grub
update-grub

# 调整网络队列处理算法（Qdiscs），优化TCP重传次数
for interface in $interfaces; do
    echo "Tuning network queue disciplines (Qdiscs) and TCP retransmission for interface $interface..."
    sudo tc qdisc add dev $interface root fq
    sudo tc qdisc change dev $interface root fq maxrate 90mbit
    sudo tc qdisc change dev $interface root fq burst 15k
    sudo tc qdisc add dev $interface ingress
    sudo tc filter add dev $interface parent ffff: protocol ip u32 match u32 0 0 action connmark action mirred egress redirect dev ifb0
    sudo tc qdisc add dev ifb0 root sfq perturb 10
    sudo ip link set dev ifb0 up
    sudo ethtool -K $interface tx off rx off
done

# 调整TCP和UDP流量的优先级
for interface in $interfaces; do
    echo "Setting priority for TCP and UDP traffic on interface $interface..."
    sudo iptables -A OUTPUT -t mangle -p tcp -o $interface -j MARK --set-mark 10
    sudo iptables -A OUTPUT -t mangle -p udp -o $interface -j MARK --set-mark 20
    sudo iptables -A PREROUTING -t mangle -i $interface -j MARK --set-mark 10
    sudo iptables -A PREROUTING -t mangle -p udp -i $interface -j MARK --set-mark 20
done

# 设置文件描述符限制脚本
#!/bin/bash

# 获取内存大小（单位：MB）
total_memory=$(free -m | awk '/^Mem:/{print $2}')

# 计算文件描述符限制数值
if [[ $total_memory -eq 512 ]]; then
    limit=4096
else
    # 每增加512MB内存，文件描述符限制数值乘以2
    multiplier=$((total_memory / 512))
    limit=$((4096 * multiplier))
fi

# 设置文件描述符限制
echo "* hard nofile $limit" >> /etc/security/limits.conf
echo "* soft nofile $limit" >> /etc/security/limits.conf

echo "文件描述符限制已设置为 $limit"

# 提示用户重启系统
echo "系统优化完成,重启系统以应用新的内核"
