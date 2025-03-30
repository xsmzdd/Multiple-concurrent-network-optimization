#!/bin/bash

# 检测是否为 Debian 11（Bullseye）
if grep -q "bullseye" /etc/os-release; then
    echo "检测到 Debian 11（Bullseye），正在修复 APT 源..."
    
    # 备份原 sources.list
    echo "备份原来的 /etc/apt/sources.list..."
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

    # 修改 sources.list 以使用 archive.debian.org
    echo "更新 /etc/apt/sources.list..."
    echo "deb http://archive.debian.org/debian bullseye main contrib non-free" | sudo tee /etc/apt/sources.list
    echo "deb http://archive.debian.org/debian-security bullseye-security main contrib non-free" | sudo tee -a /etc/apt/sources.list
    echo "deb http://archive.debian.org/debian bullseye-updates main contrib non-free" | sudo tee -a /etc/apt/sources.list

    # 禁用 APT 过期检查
    echo "APT::Acquire::Check-Valid-Until false;" | sudo tee /etc/apt/apt.conf.d/99no-check-valid-until

    # 更新 APT
    sudo apt-get update
else
    echo "当前系统不是 Debian 11（Bullseye），跳过 APT 源修复。"
fi

# 检查并安装 sudo
if ! command -v sudo &>/dev/null; then
    echo "sudo 未安装，正在安装..."
    apt-get update && apt-get install -y sudo
else
    echo "sudo 已安装"
fi

# 检查并安装 wget
if ! command -v wget &>/dev/null; then
    echo "wget 未安装，正在安装..."
    apt-get update && apt-get install -y wget
else
    echo "wget 已安装"
fi

# 检查并安装 yum（在 Debian 上使用 dnf 代替）
if ! command -v yum &>/dev/null; then
    echo "yum 未安装，正在安装..."
    apt-get update && apt-get install -y dnf
else
    echo "yum 已安装"
fi

# 检查并安装 curl
if ! command -v curl &>/dev/null; then
    echo "curl 未安装，正在安装..."
    apt-get update && apt-get install -y curl
else
    echo "curl 已安装"
fi

echo "所有必要的软件包已经安装完成，并已修复 Debian 11 APT 源（如果适用）。"
