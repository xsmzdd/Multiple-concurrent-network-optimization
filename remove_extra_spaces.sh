#!/bin/bash

# 定义目标文件路径
TARGET_FILE="/etc/systemd/system/nezha-agent.service"

# 使用 sed 删除多余的空格，保留一个空格
sed -i 's/\([[:space:]]\{2,\}\)\(--tls\|"\--tls"\)/ \2/g' "$TARGET_FILE"

echo "已处理多余空格，保留一个空格在 '--tls' 或 '\"--tls\"' 前面。"

# 重新加载 systemd 并重启服务
sudo /usr/bin/systemctl daemon-reload && \
sudo /usr/bin/systemctl restart nezha-agent.service

echo "服务已重启。"
