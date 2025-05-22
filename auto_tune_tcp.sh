#!/bin/bash

# 彩色输出控制
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RED='\e[1;31m'
BLUE='\e[1;34m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
RESET='\e[0m'

# 检查并安装 jq 和 bc
DEPENDENCIES=(jq bc)
for pkg in "${DEPENDENCIES[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo -e "${YELLOW}🔧 正在安装 $pkg...${RESET}"
        sudo apt update >/dev/null
        sudo apt install -y "$pkg" >/dev/null
    else
        echo -e "${GREEN}✅ 已安装 $pkg${RESET}"
    fi
done

# 将 MiB 转为字节
mib_to_bytes() {
    echo $(( $1 * 1024 * 1024 ))
}

# 输入验证函数
validate_number() {
    local input=$1
    if [[ ! $input =~ ^[0-9]+$ ]] || (( input <= 0 )); then
        echo -e "${RED}错误：请输入有效的正整数。${RESET}"
        return 1
    fi
    return 0
}

# 初始配置
read -p "🌐 请输入目标 IP：" TARGET_IP

# 输入本地和测试端带宽
while true; do
    read -p "📡 请输入本地带宽（Mbps）：" LOCAL_BW
    validate_number "$LOCAL_BW" && break
done

while true; do
    read -p "📡 请输入测试端带宽（Mbps）：" REMOTE_BW
    validate_number "$REMOTE_BW" && break
done

# 计算瓶颈带宽
BOTTLENECK_BW=$(( LOCAL_BW < REMOTE_BW ? LOCAL_BW : REMOTE_BW ))

# 测量平均 RTT（兼容IPv4/IPv6）
echo -e "${CYAN}🕒 正在测量到 ${TARGET_IP} 的 RTT...${RESET}"

# 判断是否为IPv6地址
if [[ $TARGET_IP == *:* ]]; then
    PING_CMD="ping6"
else
    PING_CMD="ping"
fi

# 执行ping命令并获取平均RTT
PING_RESULT=$($PING_CMD -c 4 "$TARGET_IP" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
if [[ -z $PING_RESULT ]]; then
    # 如果失败，尝试用ping -6（某些系统可能没有ping6命令）
    PING_RESULT=$(ping -6 -c 4 "$TARGET_IP" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
    if [[ -z $PING_RESULT ]]; then
        echo -e "${RED}⚠️ 无法获取 RTT，请检查：\n1. 目标IP是否正确\n2. 网络是否连通\n3. 防火墙是否允许ICMP请求${RESET}"
        exit 1
    fi
fi

RTT_MS=$(printf "%.0f" "$PING_RESULT")
RTT_S=$(echo "scale=3; $RTT_MS / 1000" | bc)

# 计算 BDP（修复单位转换错误）
BDP_BITS=$(echo "$BOTTLENECK_BW * 1000000 * $RTT_S" | bc)
BDP_BYTES=$(echo "$BDP_BITS / 8" | bc)
THEORY_VAL_MIB=$(echo "scale=2; $BDP_BYTES / (1024*1024)" | bc | awk '{printf("%d\n", $1 + 0.5)}')  # 四舍五入

# 设置初始缓冲区为 BDP 的 10 倍（最低1 MiB）
INITIAL_VAL_MIB=$(( THEORY_VAL_MIB * 10 ))
if (( INITIAL_VAL_MIB < 1 )); then
    INITIAL_VAL_MIB=1
fi

# 测试轮次配置
MAX_ATTEMPTS=10
ATTEMPT=0

# 计算递减步长（确保最后一轮为1 MiB）
if (( INITIAL_VAL_MIB > MAX_ATTEMPTS )); then
    STEP=$(( (INITIAL_VAL_MIB - 1) / (MAX_ATTEMPTS - 1) ))
else
    STEP=1
fi

declare -a TEST_LOGS=()

echo -e "\n${CYAN}🚀 理论 BDP 计算：${RESET}"
echo -e "  - 瓶颈带宽：${BOTTLENECK_BW} Mbps"
echo -e "  - 平均 RTT：${RTT_MS} ms"
echo -e "  - 理论缓冲区：${THEORY_VAL_MIB} MiB"
echo -e "  - 初始测试缓冲区：${INITIAL_VAL_MIB} MiB（理论值 × 10）"
echo -e "  - 递减步长：${STEP} MiB/轮"

echo -e "\n${CYAN}🚀 开始自动调整 TCP 缓冲区...${RESET}"

# 计算每轮缓冲区大小
BUFFER_SIZES=()
for (( i=0; i<MAX_ATTEMPTS; i++ )); do
    if (( i == MAX_ATTEMPTS - 1 )); then
        # 最后一轮强制为1 MiB
        BUFFER_SIZES+=(1)
    else
        # 其他轮次按步长递减
        CURRENT=$(( INITIAL_VAL_MIB - i * STEP ))
        (( CURRENT < 1 )) && CURRENT=1
        BUFFER_SIZES+=($CURRENT)
    fi
done

for CUR_VAL_MIB in "${BUFFER_SIZES[@]}"; do
    ((ATTEMPT++))
    echo -e "\n🧪 第 ${ATTEMPT} 轮测试：缓冲区大小为 ${BLUE}${CUR_VAL_MIB} MiB${RESET}"
    BUFFER_BYTES=$(mib_to_bytes $CUR_VAL_MIB)

    # 动态设置内核参数
    sysctl -w net.ipv4.tcp_wmem="4096 16384 $BUFFER_BYTES" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $BUFFER_BYTES" >/dev/null 2>&1

    # 执行 iperf3 测试
    RESULT_JSON=$(iperf3 -c "$TARGET_IP" -t 10 --json 2>/dev/null)
    if [[ -z "$RESULT_JSON" ]]; then
        echo -e "${RED}⚠️ iperf3 测试失败或无返回数据，请检查目标 IP 或服务状态。${RESET}"
        exit 1
    fi

    # 解析结果
    RETRANSMITS=$(echo "$RESULT_JSON" | jq '.end.sum_sent.retransmits // .end.streams[0].sender.retransmits // 0')
    SPEED=$(echo "$RESULT_JSON" | jq '.end.sum_sent.bits_per_second // .end.streams[0].sender.bits_per_second // 0 | floor')

    if (( SPEED == 0 )); then
        echo -e "${RED}❌ 测速失败（速率为 0），可能目标端未启动 iperf3 或网络不通！${RESET}"
        exit 1
    fi

    SPEED_MBPS=$(( SPEED / 1000000 ))
    echo -e "📊 当前速率：${GREEN}${SPEED_MBPS} Mbit/s${RESET}，重传次数：${YELLOW}${RETRANSMITS}${RESET}"

    # 记录测试结果
    TEST_LOGS+=("${CUR_VAL_MIB}:${SPEED}:${RETRANSMITS}")
done

# 自动选择最佳结果（最低重传优先，速率次优）
MIN_RETRANS=999999999
CANDIDATES=()

# 第一步：找到最小重传次数
for LOG in "${TEST_LOGS[@]}"; do
    RETR=$(echo "$LOG" | cut -d':' -f3)
    if (( RETR < MIN_RETRANS )); then
        MIN_RETRANS=$RETR
    fi
done

# 第二步：筛选所有等于最小重传次数的记录
for LOG in "${TEST_LOGS[@]}"; do
    MIB=$(echo "$LOG" | cut -d':' -f1)
    SPEED=$(echo "$LOG" | cut -d':' -f2)
    RETR=$(echo "$LOG" | cut -d':' -f3)
    
    if (( RETR == MIN_RETRANS )); then
        CANDIDATES+=("$MIB:$SPEED:$RETR")
    fi
done

# 第三步：在候选中选择速率最高的
BEST_SPEED=0
BEST_MIB=0
BEST_RETRANS=0
for CANDIDATE in "${CANDIDATES[@]}"; do
    MIB=$(echo "$CANDIDATE" | cut -d':' -f1)
    SPEED=$(echo "$CANDIDATE" | cut -d':' -f2)
    RETR=$(echo "$CANDIDATE" | cut -d':' -f3)
    
    if (( SPEED > BEST_SPEED )); then
        BEST_SPEED=$SPEED
        BEST_MIB=$MIB
        BEST_RETRANS=$RETR
    fi
done

# 输出结果
if (( BEST_MIB > 0 )); then
    FINAL_VAL_MIB=$BEST_MIB
    SPEED_MBPS=$(( BEST_SPEED / 1000000 ))
    echo -e "\n${YELLOW}⚙️ 自动选择最佳记录：缓冲区 ${BEST_MIB} MiB，速率 ${SPEED_MBPS} Mbps，重传 ${BEST_RETRANS}${RESET}"
else
    echo -e "\n${RED}❌ 未能确定最终参数，请手动检查测试结果${RESET}"
    exit 1
fi

# 写入系统配置
FINAL_BYTES=$(mib_to_bytes $FINAL_VAL_MIB)

# 清空 sysctl.conf
> /etc/sysctl.conf

echo -e "\n🔧 ${CYAN}将稳定值写入 ${BLUE}/etc/sysctl.conf${RESET}："
echo -e "  - net.ipv4.tcp_wmem = 4096 16384 ${MAGENTA}${FINAL_BYTES}${RESET}"
echo -e "  - net.ipv4.tcp_rmem = 4096 87380 ${MAGENTA}${FINAL_BYTES}${RESET}"

echo "net.ipv4.tcp_wmem = 4096 16384 $FINAL_BYTES" >> /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 $FINAL_BYTES" >> /etc/sysctl.conf

sysctl -p

# 输出摘要
echo -e "\n${GREEN}✅ 调整完成并已生效！最终缓冲区为 ${FINAL_VAL_MIB} MiB（${FINAL_BYTES} 字节）${RESET}"
echo -e "\n📋 ${CYAN}测试摘要：${RESET}"
echo -e "  🌟 最终缓冲区：${FINAL_VAL_MIB} MiB"
echo -e "  📀 字节值：${FINAL_BYTES}"
echo -e "  🛁 最佳测速速率：${SPEED_MBPS} Mbit/s"
echo -e "  🔁 对应重传次数：${BEST_RETRANS}"
