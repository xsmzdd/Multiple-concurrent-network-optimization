#!/bin/bash

# 定义一个日志函数
log() {
    echo "[INFO] $1"
}

log "开始安装软件包..."

# 安装 sudo
log "安装 sudo..."
apt-get install -y sudo

# 安装 wget
log "安装 wget..."
apt-get install -y wget

# 更新软件包索引
log "更新软件包索引..."
sudo apt-get update

# 安装 build-essential
log "安装 build-essential..."
sudo apt-get install -y build-essential

# 安装 yum
log "安装 yum..."
sudo apt-get install -y yum

# 安装 curl
log "安装 curl..."
sudo apt-get install -y curl

# 更新和升级系统
log "更新和升级系统..."
apt-get update && apt-get upgrade -y && apt-get dist-upgrade -y

log "所有操作已完成！"
