#!/bin/bash

# MPTCP 内核安装脚本
# 功能：检测系统 -> 下载安装包 -> 安装内核 -> 清理旧内核 -> 更新GRUB -> 重启

# 下载地址（请根据实际情况修改）
LINUX_IMAGE_URL="https://www.money-taoist.vip/tool/mptcp/linux-image-5.4.243+_5.4.243+-1_amd64.deb"
LINUX_HEADERS_URL="https://www.money-taoist.vip/tool/mptcp/linux-headers-5.4.243+_5.4.243+-1_amd64.deb"

# 1. 检测系统是否为Debian
if ! grep -q "Debian" /etc/os-release; then
    echo "错误：本脚本仅支持Debian系统！"
    exit 1
fi

# 2. 下载文件到/tmp
echo "正在下载内核文件..."
wget -q "$LINUX_IMAGE_URL" -O /tmp/linux-image-5.4.243+_5.4.243+-1_amd64.deb || {
    echo "下载linux-image失败！"
    exit 1
}

wget -q "$LINUX_HEADERS_URL" -O /tmp/linux-headers-5.4.243+_5.4.243+-1_amd64.deb || {
    echo "下载linux-headers失败！"
    exit 1
}

# 3. 安装内核
echo "正在安装内核..."
cd /tmp
sudo apt install -y ./linux-image-5.4.243+_5.4.243+-1_amd64.deb
sudo apt install -y ./linux-headers-5.4.243+_5.4.243+-1_amd64.deb

# 4. 清理旧内核
echo "正在清理旧内核..."
KEEP_KERNELS=("linux-image-5.4.243+" "linux-headers-5.4.243+")

# 获取所有已安装的内核包
ALL_KERNELS=$(dpkg --list | grep -E 'linux-image|linux-headers' | awk '{print $2}')

# 删除不需要的内核
for kernel in $ALL_KERNELS; do
    keep=0
    for keep_kernel in "${KEEP_KERNELS[@]}"; do
        if [[ "$kernel" == *"$keep_kernel"* ]]; then
            keep=1
            break
        fi
    done
    
    if [ $keep -eq 0 ]; then
        echo "正在删除内核: $kernel"
        sudo apt remove -y --purge "$kernel"
    fi
done

# 5. 清理系统
echo "正在清理系统..."
sudo apt-get update
sudo apt-get autoremove -y

# 6. 更新GRUB
echo "正在更新GRUB配置..."
sudo update-grub

# 7. 重启系统
echo "MPTCP内核安装完成，系统将在10秒后重启..."
echo "如果要取消重启，请立即按Ctrl+C！"
sleep 10
sudo reboot
