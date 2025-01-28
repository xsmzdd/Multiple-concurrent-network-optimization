#!/bin/bash
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# ███████ 初始化检查 █████████████████████████████████
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 错误：必须使用 root 权限运行本脚本${NC}" >&2
        exit 1
    fi
}

# ███████ 生产环境验证 █████████████████████████████████
validate_environment() {
    echo -e "${YELLOW}===> 验证生产环境...${NC}"
    
    # 检查系统发行版
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}❌ 错误：无法检测操作系统${NC}" >&2
        exit 1
    fi

    source /etc/os-release
    local supported_os=("debian 11" "debian 12" "ubuntu 20.04")
    local os_match=0

    for os in "${supported_os[@]}"; do
        if [[ "$ID" == "${os%% *}" && "$VERSION_ID" == "${os##* }" ]]; then
            os_match=1
            break
        fi
    done

    if [ $os_match -ne 1 ]; then
        echo -e "${RED}❌ 错误：不支持的操作系统${NC}" >&2
        echo -e "允许的系统："
        printf "  - ${GREEN}%s${NC}\n" "${supported_os[@]}"
        exit 1
    fi

    # 检查架构
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}❌ 错误：仅支持 x86_64 架构${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}✅ 环境验证通过 (${ID} ${VERSION_ID})${NC}"
}

# ███████ 内核版本检查 █████████████████████████████████
check_kernel_version() {
    local current_version=$(uname -r | cut -d '-' -f1)
    local required_version="4.9.0"

    if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" != "$required_version" ]; then
        echo -e "${YELLOW}⚠️ 检测到旧内核版本 (${current_version})${NC}"
        return 1
    else
        echo -e "${GREEN}✅ 当前内核版本满足要求 (${current_version})${NC}"
        return 0
    fi
}

# ███████ 内核升级函数 █████████████████████████████████
upgrade_kernel() {
    echo -e "${YELLOW}===> 开始内核升级流程...${NC}"

    # 备份重要配置
    local backup_time=$(date +%Y%m%d%H%M%S)
    echo -e "${YELLOW}--> 备份系统配置...${NC}"
    cp /etc/sysctl.conf /etc/sysctl.conf.bak_$backup_time
    echo -e "已创建备份：${GREEN}/etc/sysctl.conf.bak_${backup_time}${NC}"

    # 用户确认
    read -p "是否继续内核升级？(y/n) " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo -e "${RED}❌ 用户取消升级操作${NC}"
        exit 0
    fi

    # 发行版特定处理
    case "$ID" in
        ubuntu)
            echo -e "${YELLOW}--> 配置 Ubuntu HWE 内核...${NC}"
            apt update -qq
            apt install -y --install-recommends linux-generic-hwe-20.04
            ;;
        debian)
            echo -e "${YELLOW}--> 配置 Debian backports...${NC}"
            case "$VERSION_ID" in
                11)
                    echo "deb http://deb.debian.org/debian bullseye-backports main" > /etc/apt/sources.list.d/backports.list
                    ;;
                12)
                    echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
                    ;;
            esac
            apt update -qq
            apt -t $(lsb_release -cs)-backports install linux-image-amd64 -y
            ;;
    esac

    # 更新引导配置
    echo -e "${YELLOW}--> 更新 GRUB 配置...${NC}"
    update-grub

    echo -e "${GREEN}✅ 内核升级完成，需要重启生效！${NC}"
}

# ███████ 主执行流程 █████████████████████████████████
main() {
    check_root
    validate_environment

    if ! check_kernel_version; then
        upgrade_kernel
        read -p "是否立即重启系统？(y/n) " reboot_confirm
        if [[ "$reboot_confirm" =~ ^[Yy] ]]; then
            echo -e "${YELLOW}系统将在5秒后重启...${NC}"
            sleep 5
            reboot
        else
            echo -e "${YELLOW}请手动重启以应用新内核！${NC}"
        fi
    else
        echo -e "${GREEN}无需内核升级，脚本退出${NC}"
    fi
}

# 执行主程序
main
