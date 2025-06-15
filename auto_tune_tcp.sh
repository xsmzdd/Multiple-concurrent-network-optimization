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

# 规范化 IPv6 地址（确保格式正确）
if [[ $TARGET_IP == *:* ]]; then
    # 移除所有空格
    TARGET_IP=$(echo "$TARGET_IP" | tr -d '[:space:]')
    
    # 如果地址以 ":" 开头或结尾，移除它们
    TARGET_IP=$(echo "$TARGET_IP" | sed 's/^://; s/:$//')
    
    # 确保地址格式正确
    if [[ ! $TARGET_IP =~ ^[0-9a-fA-F:]+$ ]]; then
        echo -e "${RED}错误：IPv6 地址格式无效：$TARGET_IP${RESET}"
        exit 1
    fi
    
    # 添加方括号用于显示
    DISPLAY_IP="[$TARGET_IP]"
else
    DISPLAY_IP="$TARGET_IP"
fi

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

# 测量平均 RTT（完全重写）
echo -e "${CYAN}🕒 正在测量到 ${DISPLAY_IP} 的 RTT...${RESET}"

# 判断是否为IPv6地址
if [[ $TARGET_IP == *:* ]]; then
    # 对于IPv6，使用ping6或带-6选项的ping
    if command -v ping6 >/dev/null; then
        PING_CMD="ping6"
    else
        PING_CMD="ping"
        PING_ARGS="-6"
    fi
else
    PING_CMD="ping"
    PING_ARGS=""
fi

# 执行ping命令并获取输出
PING_OUTPUT=$($PING_CMD $PING_ARGS -c 4 "$TARGET_IP" 2>&1)

# 改进的RTT提取逻辑
RTT_VALUES=()
if [[ $PING_OUTPUT =~ "rtt min/avg/max/mdev" ]]; then
    # 提取统计行中的平均值
    RTT_AVG=$(echo "$PING_OUTPUT" | grep -oP 'rtt min\/avg\/max\/mdev = [\d.]+/[\d.]+/[\d.]+/[\d.]+' | awk -F'/' '{print $5}')
    RTT_VALUES+=("$RTT_AVG")
elif [[ $PING_OUTPUT =~ "round-trip min/avg/max" ]]; then
    # 备用统计行格式
    RTT_AVG=$(echo "$PING_OUTPUT" | grep -oP 'round-trip min\/avg\/max = [\d.]+/[\d.]+/[\d.]+' | awk -F'/' '{print $4}')
    RTT_VALUES+=("$RTT_AVG")
else
    # 从单个响应行中提取时间值
    while IFS= read -r line; do
        if [[ $line =~ time=([0-9.]+) ]]; then
            RTT_VALUES+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$PING_OUTPUT"
fi

# 计算平均值
if [ ${#RTT_VALUES[@]} -ge 1 ]; then
    SUM=0
    for val in "${RTT_VALUES[@]}"; do
        SUM=$(echo "$SUM + $val" | bc)
    done
    PING_RESULT=$(echo "scale=3; $SUM / ${#RTT_VALUES[@]}" | bc)
    
    # 确保结果有效
    if [[ ! $PING_RESULT =~ ^[0-9.]+$ ]]; then
        echo -e "${RED}错误：无法解析有效的 RTT 值${RESET}"
        echo -e "Ping 输出：\n$PING_OUTPUT"
        exit 1
    fi
    
    RTT_MS=$(printf "%.0f" "$PING_RESULT")
    RTT_S=$(echo "scale=3; $RTT_MS / 1000" | bc)
    
    echo -e "${GREEN}✅ 成功获取 RTT: ${RTT_MS} ms${RESET}"
else
    echo -e "${RED}⚠️ 无法获取 RTT，请检查：\n1. 目标IP是否正确\n2. 网络是否连通\n3. 防火墙是否允许ICMP请求${RESET}"
    echo -e "Ping 输出：\n$PING_OUTPUT"
    exit 1
fi

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
declare -a TEST_SPEEDS=()
declare -a TEST_RETRANS=()

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
    TEST_SPEEDS+=($SPEED)
    TEST_RETRANS+=($RETRANSMITS)
done

# 显示测试结果表格
echo -e "\n${CYAN}📊 测试结果汇总：${RESET}"
echo -e "轮次\t缓冲区大小(MiB)\t速率(Mbps)\t重传次数"
for i in "${!TEST_LOGS[@]}"; do
    log=${TEST_LOGS[$i]}
    buffer_mib=$(echo "$log" | cut -d':' -f1)
    speed=$(echo "$log" | cut -d':' -f2)
    retransmits=$(echo "$log" | cut -d':' -f3)
    speed_mbps=$(( speed / 1000000 ))
    echo -e "$((i+1))\t$buffer_mib\t\t$speed_mbps\t\t$retransmits"
done

# 30秒内手动选择
FINAL_VAL_MIB=0
USER_CHOICE=0
echo -e "\n${YELLOW}⏳ 请在30秒内输入选择的轮次（1-10），直接回车则自动选择：${RESET}"
read -t 30 USER_CHOICE

if [[ -n "$USER_CHOICE" && $USER_CHOICE =~ ^[0-9]+$ && $USER_CHOICE -ge 1 && $USER_CHOICE -le $MAX_ATTEMPTS ]]; then
    index=$((USER_CHOICE-1))
    FINAL_VAL_MIB=${BUFFER_SIZES[$index]}
    SPEED=${TEST_SPEEDS[$index]}
    RETRANSMITS=${TEST_RETRANS[$index]}
    SPEED_MBPS=$(( SPEED / 1000000 ))
    
    echo -e "\n${GREEN}✅ 您选择了第 ${USER_CHOICE} 轮，缓冲区大小为 ${FINAL_VAL_MIB} MiB${RESET}"
    echo -e "  📊 该轮结果：速率 ${SPEED_MBPS} Mbps，重传 ${RETRANSMITS}"
else
    # 修改后的自动选择逻辑：同时考虑速率和重传次数
    echo -e "\n${YELLOW}⏰ 30秒已到，自动选择最佳参数...${RESET}"
    
    # 创建候选数组
    declare -a CANDIDATES=()
    
    # 收集所有测试结果
    for i in "${!TEST_SPEEDS[@]}"; do
        SPEED=${TEST_SPEEDS[$i]}
        RETRANS=${TEST_RETRANS[$i]}
        MIB=${BUFFER_SIZES[$i]}
        # 将结果保存为 "速率:重传:缓冲区大小:轮次" 格式
        CANDIDATES+=("$SPEED:$RETRANS:$MIB:$((i+1))")
    done
    
    # 根据速率（降序）和重传（升序）排序
    # 使用 sort 命令：-t':' 指定分隔符，-k1nr 第一列数字降序，-k2n 第二列数字升序
    IFS=$'\n' SORTED=($(sort -t':' -k1nr -k2n <<<"${CANDIDATES[*]}"))
    unset IFS
    
    # 获取最佳结果
    if [ ${#SORTED[@]} -gt 0 ]; then
        BEST=${SORTED[0]}
        IFS=':' read -r BEST_SPEED BEST_RETRANS BEST_MIB BEST_ROUND <<< "$BEST"
        SPEED_MBPS=$(( BEST_SPEED / 1000000 ))
        
        echo -e "${YELLOW}⚙️ 自动选择最佳记录：第 ${BEST_ROUND} 轮${RESET}"
        echo -e "${YELLOW}   缓冲区: ${BEST_MIB} MiB, 速率: ${SPEED_MBPS} Mbps, 重传: ${BEST_RETRANS}${RESET}"
        FINAL_VAL_MIB=$BEST_MIB
    else
        echo -e "\n${RED}❌ 未能确定最终参数，请手动检查测试结果${RESET}"
        exit 1
    fi
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
