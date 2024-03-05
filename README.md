# Multiple-concurrent-network-optimization
多并发网络优化
淘汰-第一版学习使用
第一个优化方式
先创建一个optimization.sh文件nano optimization.sh
在编辑器中输入

#!/bin/bash

# 检测是否安装了ethtool和nmcli，如果没有则安装
if ! command -v ethtool &> /dev/null || ! command -v nmcli &> /dev/null; then
    echo "ethtool或nmcli未安装，正在安装..."
    sudo apt update
    sudo apt install -y ethtool network-manager
    echo "ethtool和nmcli已安装"
else
    echo "ethtool和nmcli已安装"
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

# 检查系统虚拟化类型，如果是 KVM，则关闭 TSO 和 GSO
if [ "$(sudo dmidecode -s system-product-name)" == "KVM" ]; then
    echo "系统虚拟化类型为 KVM，正在关闭 TSO 和 GSO..."
    for interface in $(nmcli device status | awk '{print $1}' | grep -v DEVICE); do
        sudo ethtool -K $interface tso off gso off
        echo "TSO 和 GSO 已关闭于接口 $interface"
    done
else
    echo "系统虚拟化类型非 KVM，不需要关闭 TSO 和 GSO。"
fi

# 备份 sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.bak



# 打开文件描述符限制 将硬限制和软限制都设置为65535，以允许更多的文件描述符
echo "* hard nofile 65535" >> /etc/security/limits.conf 
echo "* soft nofile 65535" >> /etc/security/limits.conf

# 调整内核参数 通过 here 文档（heredoc）向 /etc/sysctl.conf 文件中添加内核参数
cat << EOF >> /etc/sysctl.conf
# 调整网络参数 增加 TCP 最大连接数
net.core.somaxconn = 65535
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
# 开启 TCP Fast Open (TFO)
net.ipv4.tcp_fastopen = 3
# 修改系统的 Ring Buffer 大小和队列数量
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536
net.core.netdev_budget = 300
# 优化 txqueuelen 参数
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_mtu_probing = 1
# IPv6的优化
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.accept_ra_pinfo = 1
net.ipv6.conf.default.accept_ra_pinfo = 1
net.ipv6.conf.all.accept_ra_defrtr = 1
net.ipv6.conf.default.accept_ra_defrtr = 1
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.all.max_addresses = 16
net.ipv6.conf.default.max_addresses = 16
net.ipv6.conf.all.accept_redirects = 2
net.ipv6.conf.default.accept_redirects = 2
net.ipv6.conf.all.router_solicitations = 0
net.ipv6.conf.default.router_solicitations = 0
net.ipv6.conf.all.dad_transmits = 0
net.ipv6.conf.default.dad_transmits = 0
EOF

# 应用新的内核参数 使用 sysctl 命令重新加载 /etc/sysctl.conf 文件中的配置
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

大佬建议:

增加bbr开启检测
增加 IPv6 优化参数
增加TCP窗口大小优化
增加TCP 性能峰值优化
增加系统 initcwnd 参数优化
增加Ring Buffer 大小和队列数量优化
增加txqueuelen 参数优化
增加系统虚拟化为KVM则关闭 TSO 和 GSO
ethtool和nmcli检测安装
nmcli增加环缓冲的大小
调优网络设备积压队列以避免数据包丢弃
增加NIC的传输队列长度
优化TCP重传次数
调整网络队列处理算法（Qdiscs）
开启TCP Fast Open (TFO)
调整TCP和UDP流量的优先级
已经做好注释.保存文件并退出
然后运行脚本sudo bash optimization.sh
如果运行出现

debian_optimization.sh: line 2: $'\r': command not found
debian_optimization.sh: line 30: syntax error near unexpected token `$'do\r''
'ebian_optimization.sh: line 30: `for interface in $interfaces; do

请安装dos2unixsudo apt install dos2unix
将脚本转换为Unix格式dos2unix optimization.sh
再运行脚本sudo bash optimization.sh

根据[jerry048]大佬的#27-31楼的建议,挑选部分添加,但是有的优化需要搭配实际VPS配置网络环境等情况,怕添加后出现负优化的情况.所以标注出来大家自行前去学习膜拜!jerry048大佬的优化方案,我也做了一个脚本.请大家根据自己VPS的实际情况修改参数
#!/bin/bash

# 获取网卡接口名称
nic_interface=$(ip addr | grep 'state UP' | awk '{print $2}' | sed 's/.$//')

# 安装 ethtool（如果未安装）
if ! [ -x "$(command -v ethtool)" ]; then
    apt-get update
    apt-get -y install ethtool
fi

# 检查网卡丢包计数
echo "Checking NIC's missed packet count..."
ethtool -S $nic_interface | grep -e rx_no_buffer_count -e rx_missed_errors -e rx_fifo_errors -e rx_over_errors

# 增加网卡接收缓冲区大小
echo "Increasing the size of NIC's receive buffer..."
ethtool -g $nic_interface
# 设置所需的 RX 描述符值（例如，2048）
ethtool -G $nic_interface rx 2048

# 增加查询通道数
echo "Increasing the number of query channels..."
ethtool -l $nic_interface
# 设置所需的 combined 通道数（例如，4）
ethtool -L $nic_interface combined 4

# 调整中断协作设置
echo "Adjusting interrupt coalescing settings..."
ethtool -c $nic_interface
# 设置所需的 rx-usecs 和 tx-usecs 值（例如，10）
ethtool -C $nic_interface rx-usecs 10 tx-usecs 10

# 检查软中断丢包数
echo "Checking softIRQ misses..."
cat /proc/net/softnet_stat

# 增加 NIC 的接收队列大小
echo "Increasing the size of NIC's backlog..."
# 设置所需的接收队列大小（例如，10000）
sysctl -w net.core.netdev_max_backlog=10000

# 增加 netdev_budget 和 netdev_budget_usecs
echo "Increasing netdev_budget and netdev_budget_usecs..."
# 设置所需的 netdev_budget 和 netdev_budget_usecs 值（例如，50000 和 8000）
sysctl -w net.core.netdev_budget=50000
sysctl -w net.core.netdev_budget_usecs=8000

# 设置 net.ipv4.tcp_moderate_rcvbuf
echo "Enabling receive buffer auto-tuning..."
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

# 启用 TCP 窗口缩放
echo "Enabling TCP window scaling..."
sysctl -w net.ipv4.tcp_window_scaling=1

# 设置最大 TCP 窗口大小
echo "Setting maximum TCP window size..."
sysctl -w net.ipv4.tcp_workaround_signed_windows=1

# 增加最大文件描述符数
echo "Increasing the maximum number of file descriptors..."
# 设置所需的最大文件描述符数（例如，1000000）
sysctl -w fs.file-max=1000000
sysctl -w fs.nr_open=1000000

# 增加最大端口范围
echo "Increasing the maximum port range..."
# 设置所需的最大端口范围（例如，1024-65535）
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# 增加完全建立的套接字队列的最大长度
echo "Increasing the maximum queue length of completely established sockets..."
# 设置所需的最大队列长度（例如，10000）
sysctl -w net.core.somaxconn=10000

# 增加不附加到任何用户文件句柄的 TCP 套接字的最大数量
echo "Increasing the maximum number of orphaned connections..."
# 设置所需的最大孤立连接数（例如，10000）
sysctl -w net.ipv4.tcp_max_orphans=10000

# 增加 SYN_RECV 状态套接字的最大数量
echo "Increasing the maximum number of SYN_RECV sockets..."
# 设置所需的最大 SYN_RECV 套接字数（例如，10000）
sysctl -w net.ipv4.tcp_max_syn_recv=10000

# 增加 TIME_WAIT 状态套接字的最大数量
echo "Increasing the maximum number of sockets in TIME_WAIT state..."
# 设置所需的最大 TIME_WAIT 套接字数（例如，10000）
sysctl -w net.ipv4.tcp_max_tw_buckets=10000

# 快速丢弃 FIN-WAIT-2 状态的套接字
echo "Quickly discarding sockets in FIN-WAIT-2 state..."
# 设置所需的超时时间（例如，10）
sysctl -w net.ipv4.tcp_fin_timeout=10

# 设置 TCP 接收和发送缓冲区大小
echo "Setting TCP socket buffer sizes..."
# 设置所需的接收和发送缓冲区大小（例如，134217728 和 33554432）
sysctl -w net.ipv4.tcp_adv_win_scale=-2
sysctl -w net.core.rmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="8192 262144 134217728"
sysctl -w net.core.wmem_max=33554432
sysctl -w net.ipv4.tcp_wmem="8192 

此优化针对的是多并发,多,多.注意

第二个方式
网络收集的一键优化脚本(能明显优化,但部分系统会出现负优化的问题)

wget https://gist.githubusercontent.com/taurusxin/a9fc3ad039c44ab66fca0320045719b0/raw/3906efed227ee14fc5b4ac8eb4eea8855021ef19/optimize.sh && sudo bash optimize.sh

欢迎大佬们莅临指点补充 小弟也能多学点 yct019
