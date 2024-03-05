#!/bin/bash

# 更新系统
apt update && apt upgrade -y

# 检测是否安装iptables，如果没有则安装
if ! command -v iptables &> /dev/null; then
    echo "安装 iptables..."
    apt install -y iptables
fi

# 获取所有网络接口的名称
interfaces=$(ip link show | awk -F': ' '/^[0-9]+: [a-zA-Z0-9]+:/{print $2}')

# 循环遍历每个网络接口
for interface in $interfaces; do
    # 使用ip设置环缓冲的大小
    echo "Setting ring buffer size for interface $interface..."
    sudo ip link set dev $interface txqueuelen 10000

    # 调优网络设备积压队列以避免数据包丢弃
    echo "Tuning network device backlog for interface $interface..."
    sudo ip link set dev $interface txqueuelen 10000

    # 增加NIC的传输队列长度
    echo "Increasing NIC transmission queue length for interface $interface..."
    sudo ethtool -L $interface combined 10000
done

# 备份原始配置文件
cp /etc/sysctl.conf /etc/sysctl.conf.bak

# 配置内核参数
cat << EOF > /etc/sysctl.conf
# 网络调优: 基本
# 启用 TCP 时间戳
net.ipv4.tcp_timestamps=1

# 网络调优: 内核 Backlog 队列和缓存相关
# 设置默认的发送和接收缓冲区大小
net.core.wmem_default=16384
net.core.rmem_default=262144
# 设置最大的发送和接收缓冲区大小
net.core.rmem_max=536870912
net.core.wmem_max=536870912
# 设置 TCP 的接收和发送缓冲区大小
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=4096 16384 536870912
# 禁用 TCP 自动调整窗口大小
net.ipv4.tcp_adv_win_scale=-2
# TCP 协议将最大数据包缩小为最小数据包的上限
net.ipv4.tcp_collapse_max_bytes=6291456
# TCP 发送队列满时，内核会将套接字标记为可写入的下限
net.ipv4.tcp_notsent_lowat=131072
# 设置网络设备接收队列的最大长度
net.core.netdev_max_backlog=10240
# 设置 TCP SYN 队列的最大长度
net.ipv4.tcp_max_syn_backlog=10240
# 设置系统同时保持 SYN_RECV 状态的最大连接数
net.core.somaxconn=8192
# 当连接数达到上限时丢弃新的连接
net.ipv4.tcp_abort_on_overflow=1
# 设置默认的网络队列调度器为 FQ
net.core.default_qdisc=fq
# 启用 TCP 窗口缩放选项
net.ipv4.tcp_window_scaling=1
# 关闭空闲连接的慢启动
net.ipv4.tcp_slow_start_after_idle=0

# 网络调优: 其他
# 启用 SACK 和 FACK 选项
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
# 设置 TCP SYN 连接的重试次数
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
# 设置 TCP SYN 连接超时重试时间
net.ipv4.tcp_retries2=5
# 禁用 SYN 洪水攻击保护
net.ipv4.tcp_syncookies=0
# 设置反向路径过滤
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
# 设置 TCP FIN 连接的超时时间
net.ipv4.tcp_fin_timeout=10
# 禁用保存 TCP 连接信息
net.ipv4.tcp_no_metrics_save=1
# 设置 UNIX 套接字的最大队列长度
net.unix.max_dgram_qlen=1024
# 设置路由缓存刷新频率
net.ipv4.route.gc_timeout=100
# 启用 MTU 探测
net.ipv4.tcp_mtu_probing=1
# 启用并记录欺骗、源路由和重定向包
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
# 禁用接受源路由的包
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
# 配置 TCP KeepAlive
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_intvl=2
# 设置系统所能处理不属于任何进程的 TCP sockets 最大数量
net.ipv4.tcp_max_orphans=262144
# ARP 表的缓存限制优化
net.ipv4.neigh.default.gc_thresh1=128
net.ipv4.neigh.default.gc_thresh2=512
net.ipv4.neigh.default.gc_thresh3=4096
net.ipv4.neigh.default.gc_stale_time=120
# ARP 报文的发送规则
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2

# 内核调优
# 系统 Panic 后 1 秒自动重启
kernel.panic=1
# 允许更多的 PID
kernel.pid_max=32768
# 内核允许的最大共享内存段的大小
kernel.shmmax=4294967296
# 在任何给定时刻，系统上可以使用的共享内存的总量
kernel.shmall=1073741824
# 设置程序 core dump 时生成的文件名格式
kernel.core_pattern=core_%e
# 当发生 OOM 时，自动触发系统 Panic
vm.panic_on_oom=1
# 决定系统回收内存时对文件系统缓存的倾向程度
vm.vfs_cache_pressure=250
# 决定系统进行交换行为的程度
vm.swappiness=10
# 设置系统 dirty 内存的比例
vm.dirty_ratio=10
# 控制内存过量分配
vm.overcommit_memory=1
# 增加系统文件描述符限制
fs.file-max=1048575
fs.inotify.max_user_instances=8192
# 决定是否开启内核响应魔术键
kernel.sysrq=1
# 控制内存回收机制
vm.zone_reclaim_mode=0
EOF

# 应用新的内核参数
sysctl -p

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

# 设置文件描述符限制
total_memory=$(free -m | awk '/^Mem:/{print $2}')

if [[ $total_memory -eq 512 ]]; then
    limit=4096
else
    # 每增加512MB内存，文件描述符限制数值乘以2
    multiplier=$((total_memory / 512))
    limit=$((4096 * multiplier))
fi

echo "* hard nofile $limit" | sudo tee -a /etc/security/limits.conf
echo "* soft nofile $limit" | sudo tee -a /etc/security/limits.conf

echo "文件描述符限制已设置为 $limit"

# 提示用户重启系统
echo "系统优化完成,重启系统以应用新的内核"
