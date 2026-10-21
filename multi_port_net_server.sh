#!/bin/bash
set -euo pipefail

# ==============================================
BASE_PORT=5001          # 起始端口（固定5001）
# ==============================================

declare -a SERVER_PIDS=()
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_deps(){
    if ! command -v iperf3 &>/dev/null;then
        echo -e "${RED}[错误] 缺少iperf3${NC}"
        echo "安装: apt update && apt install iperf3 -y"
        exit 1
    fi
}

show_menu(){
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}        多端口网络稳定性测试工具 - 服务端           ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  ${GREEN}1${NC} | 启动 TCP 测试服务端"
    echo -e "  ${GREEN}2${NC} | 启动 UDP 测试服务端"
    echo -e "  ${GREEN}3${NC} | 启动 TCP+UDP 通用服务端 (T/U模式)"
    echo -e "  ${GREEN}0${NC} | 停止所有服务并退出"
    echo -e "${CYAN}====================================================${NC}"
    echo -n "请输入选项 [0-3] : "
}

# 清理所有启动的iperf3进程
clean_servers(){
    if [ ${#SERVER_PIDS[@]} -gt 0 ];then
        echo -e "${YELLOW}正在停止所有iperf3服务进程...${NC}"
        for pid in "${SERVER_PIDS[@]}";do
            kill "$pid" 2>/dev/null || true
        done
        SERVER_PIDS=()
        echo -e "${GREEN}已清理所有服务进程${NC}"
    fi
}

# 批量启动服务端
start_servers(){
    local mode_name="$1"
    local port_count
    read -p "请输入启动端口数量: " port_count

    if ! [[ "$port_count" =~ ^[0-9]+$ ]] || [ "$port_count" -lt 1 ];then
        echo -e "${RED}请输入有效的端口数量${NC}"
        sleep 1
        return
    fi

    # 先清理旧进程
    clean_servers

    echo -e "\n${CYAN}正在启动 ${mode_name} 服务端...${NC}"
    for ((i=0; i<port_count; i++));do
        port=$(( BASE_PORT + i ))
        iperf3 -s -p "$port" -D --pidfile "/tmp/iperf3_${port}.pid"
        SERVER_PIDS+=($(cat "/tmp/iperf3_${port}.pid"))
        echo -e "${GREEN}[OK] 端口 ${port} 已启动${NC}"
    done

    echo -e "\n${GREEN}=============================================${NC}"
    echo -e "  服务端启动完成，共 ${port_count} 个端口"
    echo -e "  端口范围: ${BASE_PORT} ~ $(( BASE_PORT + port_count - 1 ))"
    echo -e "  支持模式: ${mode_name}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${YELLOW}提示: 返回菜单选 0 可停止所有服务${NC}"
    read -p "按回车返回主菜单..."
}

main(){
    check_deps
    trap clean_servers EXIT

    while true;do
        show_menu
        read -r opt
        case $opt in
            1) start_servers "TCP" ;;
            2) start_servers "UDP" ;;
            3) start_servers "TCP+UDP通用" ;;
            0)
                clean_servers
                echo -e "${GREEN}已退出脚本${NC}"
                exit 0
            ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
            ;;
        esac
    done
}

main
