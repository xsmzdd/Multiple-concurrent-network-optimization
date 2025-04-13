#!/bin/bash

# MPTCP 内核安装脚本
# 版本：自动检测本地deb包

# 下载地址
LINUX_IMAGE_URL="https://tool.money-taoist.com/MPTCP/linux-image-5.4.243+_5.4.243+-1_amd64.deb"
LINUX_HEADERS_URL="https://tool.money-taoist.com/MPTCP/linux-headers-5.4.243+_5.4.243+-1_amd64.deb"

# 文件路径
IMAGE_DEB="/tmp/linux-image-5.4.243+_5.4.243+-1_amd64.deb"
HEADERS_DEB="/tmp/linux-headers-5.4.243+_5.4.243+-1_amd64.deb"

# 1. 检测系统是否为Debian
if ! grep -q "Debian" /etc/os-release; then
    echo "错误：本脚本仅支持Debian系统！"
    exit 1
fi

# 2. 检查本地是否已有deb包
need_download=0
if [[ ! -f "$IMAGE_DEB" ]] || [[ ! -f "$HEADERS_DEB" ]]; then
    need_download=1
    echo "检测到缺少deb安装包，准备下载..."
else
    echo "检测到本地已存在deb安装包，跳过下载..."
fi

# 3. 下载文件（如需）
if [[ $need_download -eq 1 ]]; then
    echo "正在下载内核文件（跳过SSL验证）..."
    wget --no-check-certificate "$LINUX_IMAGE_URL" -O "$IMAGE_DEB" || {
        echo "下载linux-image失败！请检查网络或URL"
        exit 1
    }

    wget --no-check-certificate "$LINUX_HEADERS_URL" -O "$HEADERS_DEB" || {
        echo "下载linux-headers失败！请检查网络或URL"
        exit 1
    }
fi

# 4. 验证deb包完整性
echo "验证deb包完整性..."
if ! file "$IMAGE_DEB" | grep -q "Debian binary package"; then
    echo "错误：linux-image包损坏！"
    exit 1
fi

if ! file "$HEADERS_DEB" | grep -q "Debian binary package"; then
    echo "错误：linux-headers包损坏！"
    exit 1
fi

# 5. 安装内核
echo "正在安装内核..."
cd /tmp
sudo apt install -y ./linux-image-5.4.243+_5.4.243+-1_amd64.deb
sudo apt install -y ./linux-headers-5.4.243+_5.4.243+-1_amd64.deb

# 6. 清理旧内核
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

# 7. 清理系统
echo "正在清理系统..."
sudo apt-get update
sudo apt-get autoremove -y

# 8. 更新GRUB
echo "正在更新GRUB配置..."
sudo update-grub

# 9. 重启系统
echo "MPTCP内核安装完成，系统将在10秒后重启..."
echo "如果要取消重启，请立即按Ctrl+C！"
sleep 10
sudo reboot
