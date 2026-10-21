#!/bin/bash
set -euo pipefail

# ===================== 配置区，自己改这里 =====================
SERVER_IP="1.2.3.4"       # iperf3服务端IP
BASE_PORT=5001            # 起始端口
PORT_COUNT=4              # 一共开多少个端口并发
THREAD_PER_PORT=1         # 每个端口几条流（iperf3 -P）
TEST_DURATION=30          # 单次测试秒数
INTERVAL=1                 # iperf3 报告间隔
LOG_DIR="./net_test_logs"
RUN_ID=$(date +%Y%m%d_%H%M%S)
# =============================================================

# 检查依赖
if ! command -v iperf3 &> /dev/null; then
    echo "[ERROR] iperf3 未安装，执行 apt install iperf3"
    exit 1
fi

mkdir -p "${LOG_DIR}/${RUN_ID}"
LOG_PREFIX="${LOG_DIR}/${RUN_ID}"
PID_LIST=()

echo "============================================="
echo "多端口并发网络稳定性测试启动"
echo "服务端: ${SERVER_IP}"
echo "起始端口: ${BASE_PORT}  端口数量: ${PORT_COUNT}"
echo "单端口并发流: ${THREAD_PER_PORT}"
echo "测试时长: ${TEST_DURATION}s"
echo "日志目录: ${LOG_PREFIX}"
echo "============================================="

# 循环启动每个端口的 iperf3 客户端，后台跑
for ((i=0; i<PORT_COUNT; i++)); do
    PORT=$(( BASE_PORT + i ))
    LOG_FILE="${LOG_PREFIX}/port_${PORT}.log"
    CSV_FILE="${LOG_PREFIX}/port_${PORT}.csv"

    echo "[START] 端口 ${PORT} 后台测试，日志: ${LOG_FILE}"
    # iperf3 参数说明
    # -c 客户端，-p 端口，-t 时长，-i 输出间隔，-P 多流，--logfile 原始日志，-J json 适合解析
    iperf3 -c "${SERVER_IP}" -p "${PORT}" -t "${TEST_DURATION}" -i "${INTERVAL}" -P "${THREAD_PER_PORT}" --logfile "${LOG_FILE}" -J > "${CSV_FILE}" 2>&1 &
    PID_LIST+=("$!")
done

echo "等待所有测试进程结束，共 ${#PID_LIST[@]} 个任务..."
wait "${PID_LIST[@]}"

echo "所有端口测试完成！"
echo "原始日志目录：${LOG_PREFIX}"
echo ""
echo "===== 简易汇总输出 ====="
for ((i=0; i<PORT_COUNT; i++)); do
    PORT=$(( BASE_PORT + i ))
    LOG_FILE="${LOG_PREFIX}/port_${PORT}.log"
    echo "--- 端口 ${PORT} ---"
    # 提取最后一行汇总带宽
    grep -E "sender|receiver" "${LOG_FILE}" | tail -2
done

echo ""
echo "如需分析抖动/丢包，使用 jq 解析 *.csv(json) 文件，示例："
echo "jq '.end.sum_sent' ${LOG_PREFIX}/port_${BASE_PORT}.csv"
