#!/bin/bash

# 检查并安装 jq
if ! command -v jq >/dev/null 2>&1; then
    echo "🔧 正在安装 jq..."
    sudo apt update >/dev/null
    sudo apt install -y jq >/dev/null
else
    echo "✅ 已安装 jq"
fi

# 检查并安装 dos2unix
if ! command -v dos2unix >/dev/null 2>&1; then
    echo "🔧 正在安装 dos2unix..."
    sudo apt update >/dev/null
    sudo apt install -y dos2unix >/dev/null
else
    echo "✅ 已安装 dos2unix"
fi

# 修复脚本换行符
echo "🧹 修复脚本换行符格式 (dos2unix)..."
dos2unix "$0" >/dev/null

# 将 MiB 转为字节
mib_to_bytes() {
    echo $(( $1 * 1024 * 1024 ))
}

# 初始配置
read -p "请输入目标 IP：" TARGET_IP
echo "🚀 将对 $TARGET_IP 进行 iperf3 测试并自动调整内核 TCP 缓冲区..."

# 起始缓冲区大小（MiB）
THEORY_VAL_MIB=8
CUR_VAL_MIB=$THEORY_VAL_MIB

MAX_ATTEMPTS=10
ATTEMPT=0

while (( ATTEMPT < MAX_ATTEMPTS )); do
    echo -e "\n第 $((ATTEMPT+1)) 次测试：缓冲区大小 ${CUR_VAL_MIB}MiB"
    BUFFER_BYTES=$(mib_to_bytes $CUR_VAL_MIB)

    sysctl -w net.ipv4.tcp_wmem="4096 16384 $BUFFER_BYTES" >/dev/null
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $BUFFER_BYTES" >/dev/null

    # 运行 iperf3 测试（JSON模式）并提取重传数与速率
    RESULT_JSON=$(iperf3 -c "$TARGET_IP" -t 10 --json 2>/dev/null)

    if [[ -z "$RESULT_JSON" ]]; then
        echo "⚠️ iperf3 测试失败或未返回数据，请检查网络连接或目标是否在运行 iperf3 服务。"
        exit 1
    fi

    RETRANSMITS=$(echo "$RESULT_JSON" | jq '.end.sum_sent.retransmits')
    SPEED=$(echo "$RESULT_JSON" | jq '.end.sum_sent.bits_per_second | floor')

    if [[ -z "$RETRANSMITS" || "$RETRANSMITS" == "null" ]]; then
        echo "⚠️ 未能解析重传次数，跳过调整。"
        break
    fi

    SPEED_MBPS=$(( SPEED / 1000000 ))
    echo "📊 测速速率：$SPEED_MBPS Mbit/s，重传次数：$RETRANSMITS"

    if (( RETRANSMITS == 0 )); then
        echo "🎯 0 重传，缓冲区可尝试上调 1MiB 保守优化..."
        CUR_VAL_MIB=$((CUR_VAL_MIB + 1))
        FINAL_VAL_MIB=$((CUR_VAL_MIB - 1))
        break
    elif (( RETRANSMITS <= 100 )); then
        echo "✅ 重传低（$RETRANSMITS），基本稳定"
        FINAL_VAL_MIB=$((CUR_VAL_MIB - 1))
        break
    elif (( RETRANSMITS > 1000 )); then
        echo "📉 重传高，缓冲区下调 2MiB"
        CUR_VAL_MIB=$((CUR_VAL_MIB - 2))
    else
        echo "⚠️ 有一定重传，缓冲区下调 1MiB"
        CUR_VAL_MIB=$((CUR_VAL_MIB - 1))
    fi

    ((ATTEMPT++))
done

# 写入 sysctl.conf 并生效
if [[ -n "$FINAL_VAL_MIB" ]]; then
    FINAL_BYTES=$(mib_to_bytes $FINAL_VAL_MIB)
    echo -e "\n🔧 将稳定值写入 /etc/sysctl.conf：${FINAL_VAL_MIB}MiB"

    echo "net.ipv4.tcp_wmem = 4096 16384 $FINAL_BYTES" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 $FINAL_BYTES" >> /etc/sysctl.conf

    sysctl -p

    echo "✅ 调整完成并已生效。最终缓冲区为 ${FINAL_VAL_MIB}MiB ($FINAL_BYTES bytes)"

    # 再次运行 iperf3 显示完整 JSON 结果
    echo -e "\n📈 最终 0 重传测试结果如下："
    iperf3 -c "$TARGET_IP" -t 10 --json | jq
else
    echo "❌ 未能确定最终参数，请手动检查测试结果"
fi
