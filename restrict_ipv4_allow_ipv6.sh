#!/bin/bash

# 脚本名称: restrict_ipv4_allow_ipv6.sh
# 功能: 限制IPv4出站，强制仅允许IPv6出口，并配置DNS和验证

# 必须以root权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 请使用 sudo 或以 root 用户身份运行此脚本"
  exit 1
fi

# 确认操作（防止误操作）
read -p "此操作将禁用IPv4出站流量并修改DNS配置，继续吗？[y/N] " confirm
if [[ ! "$confirm" =~ [yY] ]]; then
  echo "操作已取消"
  exit 0
fi

# -------------------------- 配置防火墙规则 --------------------------
# 设置IPv4规则：允许已建立连接和本地回环，其他出站全部禁止
iptables -F OUTPUT 2>/dev/null  # 清空现有OUTPUT链（谨慎操作！）
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -P OUTPUT DROP  # 默认丢弃所有IPv4出站

# 确保IPv6畅通（默认ACCEPT，显式设置以防万一）
ip6tables -P OUTPUT ACCEPT

# 保存规则到持久化
apt-get install -y iptables-persistent >/dev/null 2>&1
netfilter-persistent save >/dev/null 2>&1

# -------------------------- 配置IPv6 DNS --------------------------
# 定义IPv6 DNS服务器
IPV6_DNS=(
  "2001:4860:4860::8888"    # Google
  "2606:4700:4700::1111"    # Cloudflare
)

# 检测是否使用 systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
  echo "检测到 systemd-resolved，配置DNS..."
  resolvectl dns eth0 "${IPV6_DNS[@]}"
else
  echo "配置 /etc/resolv.conf..."
  sed -i '/nameserver/d' /etc/resolv.conf
  for dns in "${IPV6_DNS[@]}"; do
    echo "nameserver $dns" >> /etc/resolv.conf
  done
fi

# -------------------------- 验证配置 --------------------------
echo -e "\n验证中..."

# 测试IPv4阻断
echo -n "测试IPv4阻断: "
if ! ping -4 -c 2 8.8.8.8 &>/dev/null; then
  echo "成功（IPv4出站已阻止）"
else
  echo "失败！IPv4仍可访问"
fi

# 测试IPv6连通性
echo -n "测试IPv6连通性: "
if ping6 -c 2 ipv6.google.com &>/dev/null; then
  echo "成功（IPv6正常）"
else
  echo "失败！请检查IPv6配置"
fi

# 测试DNS解析
echo -n "测试DNS解析: "
if curl -6 -s http://ifconfig.co | grep -q ':'; then
  echo "成功（IPv6 DNS生效）"
else
  echo "失败！DNS可能未配置正确"
fi

echo -e "\n操作完成！注意：若通过IPv4连接，请勿关闭当前会话以防失联。"
