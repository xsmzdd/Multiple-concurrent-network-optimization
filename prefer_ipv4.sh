#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户或sudo运行此脚本"
    exit 1
fi

# 设置IPv6路由的优先级（更高的metric值意味着更低的优先级）
echo "正在调整IPv6路由优先级..."

# 获取所有网络接口
interfaces=$(ip -o link show | awk -F': ' '{print $2}')

for iface in $interfaces; do
    # 跳过回环接口
    if [ "$iface" = "lo" ]; then
        continue
    fi

    # 获取IPv6默认路由
    ipv6_route=$(ip -6 route show default dev "$iface" 2>/dev/null)
    if [ -n "$ipv6_route" ]; then
        # 删除现有的IPv6默认路由
        ip -6 route del default dev "$iface"
        # 添加新的IPv6默认路由，设置更高的metric值（这里使用100）
        ip -6 route add default dev "$iface" metric 100
        echo "已调整接口 $iface 的IPv6路由metric为100"
    fi
done

# 确保sysctl设置正确
echo "正在配置sysctl参数..."

# 禁用IPv6的自动路由（不影响入口流量）
sysctl -w net.ipv6.conf.all.autoconf=0
sysctl -w net.ipv6.conf.all.accept_ra=0
sysctl -w net.ipv6.conf.all.accept_ra_defrtr=0
sysctl -w net.ipv6.conf.all.accept_ra_pinfo=0
sysctl -w net.ipv6.conf.all.accept_ra_rtr_pref=0
sysctl -w net.ipv6.conf.all.accept_redirects=0
sysctl -w net.ipv6.conf.all.accept_source_route=0

# 使sysctl设置永久生效
cat > /etc/sysctl.d/60-ipv6-priority.conf <<EOF
net.ipv6.conf.all.autoconf=0
net.ipv6.conf.all.accept_ra=0
net.ipv6.conf.all.accept_ra_defrtr=0
net.ipv6.conf.all.accept_ra_pinfo=0
net.ipv6.conf.all.accept_ra_rtr_pref=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
EOF

echo "配置完成。系统将优先使用IPv4进行出口流量，同时不影响IPv6入口流量。"
echo "注意：这些设置可能在网络重启后失效，建议将此脚本设置为网络启动后自动运行。"
