#!/bin/bash

# 定义目标文件路径
SERVICE_FILE="/etc/systemd/system/nezha-agent.service"

# 检查文件中是否包含特定的 ExecStart 行
if grep -q 'ExecStart=.*nzip.moneytaoist.sbs:5555' "$SERVICE_FILE"; then
    echo "匹配到没有引号的 ExecStart 格式，执行相关命令..."
    source ~/.bashrc && \
    sudo sed -i 's|nzip.moneytaoist.sbs:5555|www.money-taoist.icu:443|g' "$SERVICE_FILE" && \
    sudo sed -i 's|--disable-auto-update|--tls --disable-auto-update|g' "$SERVICE_FILE" && \
    sudo /usr/bin/systemctl daemon-reload && \
    sudo /usr/bin/systemctl restart nezha-agent.service

elif grep -q 'ExecStart=.*"nzip.moneytaoist.sbs:5555"' "$SERVICE_FILE"; then
    echo "匹配到有引号的 ExecStart 格式，执行相关命令..."
    source ~/.bashrc && \
    sudo sed -i 's|nzip.moneytaoist.sbs:5555|www.money-taoist.icu:443|g' "$SERVICE_FILE" && \
    sudo sed -i 's|--disable-auto-update|"--tls" --disable-auto-update|g' "$SERVICE_FILE" && \
    sudo /usr/bin/systemctl daemon-reload && \
    sudo /usr/bin/systemctl restart nezha-agent.service
else
    echo "没有匹配到预定义的 ExecStart 格式，未执行任何操作。"
fi
