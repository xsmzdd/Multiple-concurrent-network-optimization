#!/bin/bash

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

# 检查并安装 yum
if ! command -v yum &>/dev/null; then
    echo "yum 未安装，正在安装..."
    apt-get update && apt-get install -y dnf  # Debian 默认没有 yum，可以使用 dnf
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

echo "所有必要的软件包已经安装完成。"