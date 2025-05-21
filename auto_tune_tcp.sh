#!/bin/bash

# 彩色输出控制
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RED='\e[1;31m'
BLUE='\e[1;34m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
RESET='\e[0m'

# 检查并安装 jq
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}🔧 正在安装 jq...${RESET}"
    sudo apt update >/dev/null
    sudo apt install -y jq >/dev/null
else
    echo -e "${GREEN}✅ 已安装 jq${RESET}"
fi

# 检查并安装 dos2unix
if ! command -v dos2unix >/dev/null 2>&1; then
    echo -e "${YELLOW}🔧 正在安装 dos2unix...${RESET}"
    sudo apt update >/dev/null
    sudo apt install -y dos2unix >/dev/null
else
    echo -e "${GREEN}✅ 已安装 dos2unix${RESET}"
fi

# 修复脚本换行符
echo -e "${CYAN}🧹 修复脚本换行符格式 (dos2unix)...${RESET}"
dos2unix "$0" >/dev/null

# 将 MiB 转为字节
mib_to_bytes() {
    echo $(( $1 * 1024 * 1024 ))
}

# 初始配置
read -p "🌐 请输入目标 IP：" TARGET_IP
echo -e "${CYAN}🚀 将对 ${TARGET_IP} 进行 iperf3 测试并自动调整内核 TCP 缓冲区...${RESET}"

THEORY_VAL_MIB=8
CUR_VAL_MIB=$THEORY_VAL_MIB
MAX_ATTEMPTS=10
ATTEMPT=0

while (( ATTEMPT < MAX_ATTEMPTS )); do
    echo -e "\n🧪 第 $((ATTEMPT+1)) 轮测试：缓冲区大小为 ${BLUE}${CUR_VAL_MIB} MiB${RESET}"
    BUFFER_BYTES=$(mib_to_bytes $CUR_VAL_MIB)

    sysctl -w net.ipv4.tcp_wmem="4096 16384 $BUFFER_BYTES" >/dev/null
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $BUFFER_BYTES" >/dev/null

    RESULT_JSON=$(iperf3 -c "$TARGET_IP" -t 10 --json 2>/dev/null)

    if [[ -z "$RESULT_JSON" ]]; then
        echo -e "${RED}⚠️ iperf3 测试失败或无返回数据，请检查目标 IP 或服务状态。${RESET}"
        exit 1
    fi

    RETRANSMITS=$(echo "$RESULT_JSON" | jq '.end.sum_sent.retransmits')
    SPEED=$(echo "$RESULT_JSON" | jq '.end.sum_sent.bits_per_second | floor')

    if [[ -z "$RETRANSMITS" || "$RETRANSMITS" == "null" ]]; then
        echo -e "${YELLOW}⚠️ 无法解析重传次数，跳过调整。${RESET}"
        break
    fi

    SPEED_MBPS=$(( SPEED / 1000000 ))
    echo -e "📊 当前速率：${GREEN}${SPEED_MBPS} Mbit/s${RESET}，重传次数：${YELLOW}${RETRANSMITS}${RESET}"

    if (( RETRANSMITS == 0 )); then
        echo -e "${GREEN}🎯 0 重传，缓冲区上调 1MiB 以保守优化...${RESET}"
        CUR_VAL_MIB=$((CUR_VAL_MIB + 1))
        FINAL_VAL_MIB=$((CUR_VAL_MIB - 1))
        break
    elif (( RETRANSMITS <= 100 )); then
        echo -e "${CYAN}✅ 重传次数较低（${RETRANSMITS}），认为当前缓冲区稳定${RESET}"
        FINAL_VAL_MIB=$((CUR_VAL_MIB - 1))
        break
    elif (( RETRANSMITS > 1000 )); then
        echo -e "${RED}📉 重传较多（${RETRANSMITS}），缓冲区下调 2MiB${RESET}"
        CUR_VAL_MIB=$((CUR_VAL_MIB - 2))
    else
        echo -e "${YELLOW}⚠️ 中度重传（${RETRANSMITS}），缓冲区下调 1MiB${RESET}"
        CUR_VAL_MIB=$((CUR_VAL_MIB - 1))
    fi

    ((ATTEMPT++))
done

# 写入 sysctl.conf 并生效
if [[ -n "$FINAL_VAL_MIB" ]]; then
    FINAL_BYTES=$(mib_to_bytes $FINAL_VAL_MIB)
    echo -e "\n🔧 ${CYAN}将稳定值写入 ${BLUE}/etc/sysctl.conf${RESET}："
    echo -e "  - net.ipv4.tcp_wmem = 4096 16384 ${MAGENTA}${FINAL_BYTES}${RESET}"
    echo -e "  - net.ipv4.tcp_rmem = 4096 87380 ${MAGENTA}${FINAL_BYTES}${RESET}"

    echo "net.ipv4.tcp_wmem = 4096 16384 $FINAL_BYTES" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 $FINAL_BYTES" >> /etc/sysctl.conf

    sysctl -p

    echo -e "\n${GREEN}✅ 调整完成并已生效！最终缓冲区为 ${FINAL_VAL_MIB} MiB（${FINAL_BYTES} 字节）${RESET}"

    # 再次测速显示最终结果（只提取摘要）
    echo -e "\n📈 最终 iperf3 测试结果摘要："
    FINAL_RESULT=$(iperf3 -c "$TARGET_IP" -t 10 --json 2>/dev/null)

    FINAL_SPEED=$(echo "$FINAL_RESULT" | jq '.end.sum_sent.bits_per_second | floor')
    FINAL_RETRANS=$(echo "$FINAL_RESULT" | jq '.end.sum_sent.retransmits')
    FINAL_SPEED_MBPS=$(( FINAL_SPEED / 1000000 ))

    echo -e "\n📋 ${CYAN}测试摘要：${RESET}"
    echo -e "  🎯 最终缓冲区：${FINAL_VAL_MIB} MiB"
    echo -e "  💾 字节值：${FINAL_BYTES}"
    echo -e "  📡 最后测速速率：${GREEN}${FINAL_SPEED_MBPS} Mbit/s${RESET}"
    echo -e "  🔁 最后重传次数：${YELLOW}${FINAL_RETRANS}${RESET}"
else
    echo -e "\n${RED}❌ 未能确定最终参数，请手动检查测试结果${RESET}"
fi
