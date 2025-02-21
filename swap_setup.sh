#!/bin/bash

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    echo "系统架构: AMD64"
elif [[ "$ARCH" == "aarch64" ]]; then
    echo "系统架构: ARM64"
else
    echo "不支持的架构: $ARCH"
    exit 1
fi

# 检测系统类型
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
        echo "检测到系统: $NAME $VERSION"
    else
        echo "不支持的系统: $NAME"
        exit 1
    fi
else
    echo "无法检测操作系统"
    exit 1
fi

# 检查是否已启用 swap
if free | awk '/^Swap:/ {exit !$2}'; then
    echo "Swap 已开启，脚本结束。"
    exit 0
else
    echo "Swap 未开启，开始创建 1GB swap。"
fi

# 创建并启用 1GB swap
SWAPFILE=/swapfile
sudo fallocate -l 1G $SWAPFILE || sudo dd if=/dev/zero of=$SWAPFILE bs=1M count=1024
sudo chmod 600 $SWAPFILE
sudo mkswap $SWAPFILE
sudo swapon $SWAPFILE

# 确保开机自动挂载 swap
if ! grep -q "$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab
fi

echo "Swap 设置完成。"
