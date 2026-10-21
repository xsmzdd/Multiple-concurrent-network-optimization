#!/bin/bash
set -euo pipefail

# ==============================================
# 【基础配置区，可按需修改】
# ==============================================
BASE_PORT=5001          # 起始端口（固定5001）
THREAD_PER_PORT=1       # 单端口并发流数
TEST_DURATION=20        # 单次测试时长(秒)
RETRY_TIMES=2           # 单端口失败重试次数
LOOP_MODE=0             # 0=单次  1=无限循环持续测试
LOOP_INTERVAL=10        # 两轮测试间隔(秒)
DEFAULT_UDP_BAND="100M" # UDP默认单端口带宽
LOG_ROOT="./nettest_logs"
# ==============================================

# 全局变量
RUN_ID=""
SERVER_IP=""
PORT_COUNT=4
PORT_BAND=""
SELECT_MODE=0
SUMMARY_CSV=""
LOG_DIR=""

# 颜色美化
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 依赖检查
check_deps(){
    local need=("iperf3" "jq" "bc")
    for bin in "${need[@]}";do
        if ! command -v "$bin" &>/dev/null;then
            echo -e "${RED}[错误] 缺少依赖工具: $bin${NC}"
            echo "安装命令: apt update && apt install iperf3 jq bc -y"
            exit 1
        fi
    done
}

# 绘制主菜单
show_menu(){
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}        多端口网络稳定性测试工具 - 客户端           ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  ${GREEN}1${NC} | TCP 单独测试"
    echo -e "  ${GREEN}2${NC} | UDP 单独测试"
    echo -e "  ${GREEN}3${NC} | TCP + UDP 依次测试 (T/U模式)"
    echo -e "  ${GREEN}4${NC} | 读取历史日志，生成汇总报告+HTML图表"
    echo -e "  ${GREEN}0${NC} | 退出脚本"
    echo -e "${CYAN}====================================================${NC}"
    echo -n "请输入选项 [0-4] : "
}

# 交互式输入参数
input_params(){
    clear
    echo -e "${CYAN}===== 测试参数配置 =====${NC}"
    
    read -p "请输入服务端IP地址: " SERVER_IP
    if [ -z "$SERVER_IP" ];then
        echo -e "${RED}服务端IP不能为空${NC}"
        sleep 1
        return 1
    fi

    read -p "请输入测试端口数量 (默认4): " PORT_COUNT
    PORT_COUNT=${PORT_COUNT:-4}

    if [ "$SELECT_MODE" = "2" ] || [ "$SELECT_MODE" = "3" ];then
        read -p "请输入单端口UDP带宽 (如100M, 默认${DEFAULT_UDP_BAND}): " PORT_BAND
        PORT_BAND=${PORT_BAND:-$DEFAULT_UDP_BAND}
    else
        read -p "请输入单端口TCP带宽限制 (回车默认不限制): " PORT_BAND
        PORT_BAND=${PORT_BAND:-}
    fi

    echo -e "\n${GREEN}配置确认:${NC}"
    echo -e "  服务端: ${SERVER_IP}"
    echo -e "  端口范围: ${BASE_PORT} ~ $(( BASE_PORT + PORT_COUNT - 1 ))"
    echo -e "  单端口带宽: ${PORT_BAND:-不限制}"
    echo -e "  测试时长: ${TEST_DURATION}s"
    read -p "确认开始测试? [Y/n] " confirm
    case $confirm in
        n|N) return 1 ;;
        *) return 0 ;;
    esac
}

# 初始化一轮测试目录
init_run(){
    RUN_ID=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="${LOG_ROOT}/${RUN_ID}"
    mkdir -p "${LOG_DIR}/tcp" "${LOG_DIR}/udp"
    SUMMARY_CSV="${LOG_DIR}/summary_all.csv"
    echo "run_id,mode,port,status,rx_mbps,tx_mbps,loss_pct,jitter_ms" > "${SUMMARY_CSV}"
}

# 数字校验函数，防止bc报错
is_number(){
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# 单端口测试（带重试，仅写CSV文件）
test_single_port(){
    local port="$1"
    local mode="$2"
    local ret=1
    local try=0
    local log_err="${LOG_DIR}/${mode}/port_${port}.err.log"
    local log_json="${LOG_DIR}/${mode}/port_${port}.json"
    local extra_args=""

    if [ "$mode" = "udp" ];then
        extra_args="-u -b ${PORT_BAND}"
    elif [ -n "$PORT_BAND" ];then
        extra_args="-b ${PORT_BAND}"
    fi

    while [ $try -le $RETRY_TIMES ];do
        set +e
        # 修复：移除--logfile，JSON输出到标准输出，错误日志单独保存
        timeout $((TEST_DURATION + 8)) iperf3 -c "${SERVER_IP}" -p "${port}" -t "${TEST_DURATION}" \
            -i 0 -P "${THREAD_PER_PORT}" ${extra_args} -J > "${log_json}" 2>"${log_err}"
        ret=$?
        set -e
        if [ $ret -eq 0 ];then break;fi
        try=$((try+1))
        sleep 1
    done

    # 解析结果
    local status="error"
    local rx_mbps="0.00"
    local tx_mbps="0.00"
    local loss_pct="0.00"
    local jitter_ms="0.00"

    if [ $ret -eq 124 ];then
        status="timeout"
    elif [ $ret -eq 0 ] && [ -s "${log_json}" ];then
        # 强校验JSON有效性
        if jq -e '.end.sum_sent and .end.sum_received' "${log_json}" &>/dev/null;then
            status="ok"
            local tx_bps rx_bps
            tx_bps=$(jq -r '.end.sum_sent.bits_per_second // 0' "${log_json}")
            rx_bps=$(jq -r '.end.sum_received.bits_per_second // 0' "${log_json}")

            # 数值校验
            is_number "$tx_bps" || tx_bps=0
            is_number "$rx_bps" || rx_bps=0

            tx_mbps=$(echo "scale=2; $tx_bps / 1000000" | bc -l)
            rx_mbps=$(echo "scale=2; $rx_bps / 1000000" | bc -l)

            if [ "$mode" = "udp" ];then
                loss_pct=$(jq -r '.end.sum_received.loss_percent // 0' "${log_json}")
                jitter_ms=$(jq -r '.end.sum_received.jitter_ms // 0' "${log_json}")
                is_number "$loss_pct" || loss_pct=0
                is_number "$jitter_ms" || jitter_ms=0
            fi
        fi
    fi

    echo "${RUN_ID},${mode},${port},${status},${rx_mbps},${tx_mbps},${loss_pct},${jitter_ms}" >> "${SUMMARY_CSV}"
}

# 批量并行测试
run_batch_test(){
    local mode="$1"
    local pids=()
    echo -e "${BLUE}[${RUN_ID}] 正在执行 ${mode^^} 测试，共 ${PORT_COUNT} 个端口...${NC}"
    
    for ((i=0; i<PORT_COUNT; i++));do
        port=$(( BASE_PORT + i ))
        test_single_port "$port" "$mode" &
        pids+=("$!")
    done
    wait "${pids[@]}"
}

# 输出本轮结果汇总（从CSV读取，按端口排序）
print_summary(){
    echo -e "\n${CYAN}==================== 本轮测试结果 ====================${NC}"
    local ok=0 timeout=0 err=0

    # 统计状态
    while IFS=',' read -r _ _ _ status _ _ _ _; do
        case "$status" in
            ok) ok=$((ok+1)) ;;
            timeout) timeout=$((timeout+1)) ;;
            error) err=$((err+1)) ;;
        esac
    done < <(tail -n +2 "${SUMMARY_CSV}")

    # 列出异常端口（按端口排序）
    echo -e "${YELLOW}----- 异常端口列表 -----${NC}"
    awk -F',' 'NR>1 && $4!="ok" {
        if($4=="timeout") printf "\033[1;33m[超时] %s 端口 %s\033[0m\n", toupper($2), $3
        else printf "\033[0;31m[异常] %s 端口 %s\033[0m\n", toupper($2), $3
    }' "${SUMMARY_CSV}" | sort -t' ' -k3 -n

    # 计算平均带宽
    echo -e "\n${GREEN}----- 带宽统计 -----${NC}"
    local avg_tcp_rx avg_tcp_tx avg_udp_rx avg_udp_tx avg_loss avg_jitter
    avg_tcp_rx=$(awk -F',' 'NR>1 && $2=="tcp" && $4=="ok" {sum+=$5; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}' "${SUMMARY_CSV}")
    avg_tcp_tx=$(awk -F',' 'NR>1 && $2=="tcp" && $4=="ok" {sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}' "${SUMMARY_CSV}")
    avg_udp_rx=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$5; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}' "${SUMMARY_CSV}")
    avg_udp_tx=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}' "${SUMMARY_CSV}")
    avg_loss=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$7; count++} END {if(count>0) printf "%.4f", sum/count; else print "0.0000"}' "${SUMMARY_CSV}")
    avg_jitter=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$8; count++} END {if(count>0) printf "%.4f", sum/count; else print "0.0000"}' "${SUMMARY_CSV}")

    if [ $SELECT_MODE -eq 1 ] || [ $SELECT_MODE -eq 3 ];then
        echo -e "TCP 平均下行: ${CYAN}${avg_tcp_rx} Mbps${NC}  |  TCP 平均上行: ${CYAN}${avg_tcp_tx} Mbps${NC}"
    fi
    if [ $SELECT_MODE -eq 2 ] || [ $SELECT_MODE -eq 3 ];then
        echo -e "UDP 平均下行: ${CYAN}${avg_udp_rx} Mbps${NC}  |  UDP 平均上行: ${CYAN}${avg_udp_tx} Mbps${NC}"
        echo -e "UDP 平均丢包: ${CYAN}${avg_loss}%${NC}  |  UDP 平均抖动: ${CYAN}${avg_jitter}ms${NC}"
    fi

    echo -e "\n${GREEN}✅ 正常: $ok  | ${YELLOW}⏱️ 超时: $timeout | ${RED}❌ 异常: $err${NC}"
    echo -e "日志目录: ${LOG_DIR}"
    echo -e "汇总文件: ${SUMMARY_CSV}"
}

# 生成HTML图表报告
gen_html_report(){
    local csv_file="$1"
    local run_id="$2"
    local html_file="${LOG_ROOT}/${run_id}/report_${run_id}.html"

    # 提取排序后的数据
    local tcp_data udp_data
    tcp_data=$(awk -F',' 'NR>1 && $2=="tcp" {print $3","$5","$6}' "$csv_file" | sort -t',' -k1 -n)
    udp_data=$(awk -F',' 'NR>1 && $2=="udp" {print $3","$5","$6","$7","$8}' "$csv_file" | sort -t',' -k1 -n)

    # 生成JS数组格式
    local tcp_ports tcp_rx tcp_tx
    tcp_ports=$(echo "$tcp_data" | awk -F',' '{print "\""$1"\""}' | paste -sd, -)
    tcp_rx=$(echo "$tcp_data" | awk -F',' '{print $2}' | paste -sd, -)
    tcp_tx=$(echo "$tcp_data" | awk -F',' '{print $3}' | paste -sd, -)

    local udp_ports udp_rx udp_tx udp_loss udp_jitter
    udp_ports=$(echo "$udp_data" | awk -F',' '{print "\""$1"\""}' | paste -sd, -)
    udp_rx=$(echo "$udp_data" | awk -F',' '{print $2}' | paste -sd, -)
    udp_tx=$(echo "$udp_data" | awk -F',' '{print $3}' | paste -sd, -)
    udp_loss=$(echo "$udp_data" | awk -F',' '{print $4}' | paste -sd, -)
    udp_jitter=$(echo "$udp_data" | awk -F',' '{print $5}' | paste -sd, -)

    # 计算平均值
    local avg_tcp_rx avg_tcp_tx avg_udp_rx avg_udp_tx avg_loss avg_jitter
    avg_tcp_rx=$(awk -F',' 'NR>1 && $2=="tcp" && $4=="ok" {sum+=$5; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}' "$csv_file")
    avg_tcp_tx=$(awk -F',' 'NR>1 && $2=="tcp" && $4=="ok" {sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}' "$csv_file")
    avg_udp_rx=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$5; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}' "$csv_file")
    avg_udp_tx=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}' "$csv_file")
    avg_loss=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$7; count++} END {if(count>0) printf "%.4f", sum/count; else print 0}' "$csv_file")
    avg_jitter=$(awk -F',' 'NR>1 && $2=="udp" && $4=="ok" {sum+=$8; count++} END {if(count>0) printf "%.4f", sum/count; else print 0}' "$csv_file")

    # 写入HTML
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>网络测试报告 - ${run_id}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f5f7fa; }
h1,h2 { color: #2c3e50; }
.card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
.stats { display: flex; gap: 20px; flex-wrap: wrap; }
.stat-item { flex: 1; min-width: 150px; padding: 15px; border-radius: 6px; background: #f0f4f8; }
.stat-label { font-size: 14px; color: #666; margin-bottom: 5px; }
.stat-value { font-size: 22px; font-weight: bold; color: #2c3e50; }
table { width: 100%; border-collapse: collapse; margin-top: 10px; }
th,td { padding: 8px 12px; border: 1px solid #e0e0e0; text-align: center; }
th { background: #f0f4f8; }
.chart-container { position: relative; height: 300px; margin: 20px 0; }
</style>
</head>
<body>
<h1>多端口网络稳定性测试报告</h1>
<div class="card">
  <h2>基本信息</h2>
  <p><strong>测试ID:</strong> ${run_id}</p>
  <p><strong>服务端IP:</strong> ${SERVER_IP:-未知}</p>
  <p><strong>测试时长:</strong> ${TEST_DURATION}s / 端口</p>
  <p><strong>端口范围:</strong> ${BASE_PORT} ~ $(( BASE_PORT + PORT_COUNT - 1 ))</p>
</div>

<div class="card">
  <h2>整体统计</h2>
  <div class="stats">
    <div class="stat-item">
      <div class="stat-label">TCP平均下行</div>
      <div class="stat-value">${avg_tcp_rx} Mbps</div>
    </div>
    <div class="stat-item">
      <div class="stat-label">TCP平均上行</div>
      <div class="stat-value">${avg_tcp_tx} Mbps</div>
    </div>
    <div class="stat-item">
      <div class="stat-label">UDP平均下行</div>
      <div class="stat-value">${avg_udp_rx} Mbps</div>
    </div>
    <div class="stat-item">
      <div class="stat-label">UDP平均丢包</div>
      <div class="stat-value">${avg_loss} %</div>
    </div>
    <div class="stat-item">
      <div class="stat-label">UDP平均抖动</div>
      <div class="stat-value">${avg_jitter} ms</div>
    </div>
  </div>
</div>

<div class="card">
  <h2>TCP 带宽对比</h2>
  <div class="chart-container"><canvas id="tcpChart"></canvas></div>
</div>

<div class="card">
  <h2>UDP 带宽对比</h2>
  <div class="chart-container"><canvas id="udpChart"></canvas></div>
</div>

<div class="card">
  <h2>UDP 丢包与抖动</h2>
  <div class="chart-container"><canvas id="udpQualityChart"></canvas></div>
</div>

<div class="card">
  <h2>详细数据表</h2>
  <table>
    <tr><th>模式</th><th>端口</th><th>状态</th><th>下行(Mbps)</th><th>上行(Mbps)</th><th>丢包(%)</th><th>抖动(ms)</th></tr>
    $(awk -F',' 'NR>1 {
        printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", toupper($2), $3, $4, $5, $6, $7, $8
    }' "$csv_file" | sort -t'</td><td>' -k2 -n)
  </table>
</div>

<script>
const tcpPorts = [${tcp_ports}];
const tcpRx = [${tcp_rx}];
const tcpTx = [${tcp_tx}];

new Chart(document.getElementById('tcpChart'), {
  type: 'bar',
  data: {
    labels: tcpPorts,
    datasets: [
      { label: '下行 Mbps', data: tcpRx, backgroundColor: 'rgba(52, 152, 219, 0.7)' },
      { label: '上行 Mbps', data: tcpTx, backgroundColor: 'rgba(46, 204, 113, 0.7)' }
    ]
  },
  options: { responsive: true, maintainAspectRatio: false }
});

const udpPorts = [${udp_ports}];
const udpRx = [${udp_rx}];
const udpTx = [${udp_tx}];

new Chart(document.getElementById('udpChart'), {
  type: 'bar',
  data: {
    labels: udpPorts,
    datasets: [
      { label: '下行 Mbps', data: udpRx, backgroundColor: 'rgba(155, 89, 182, 0.7)' },
      { label: '上行 Mbps', data: udpTx, backgroundColor: 'rgba(241, 196, 15, 0.7)' }
    ]
  },
  options: { responsive: true, maintainAspectRatio: false }
});

const udpLoss = [${udp_loss}];
const udpJitter = [${udp_jitter}];

new Chart(document.getElementById('udpQualityChart'), {
  type: 'line',
  data: {
    labels: udpPorts,
    datasets: [
      { label: '丢包率 %', data: udpLoss, borderColor: '#e74c3c', yAxisID: 'y' },
      { label: '抖动 ms', data: udpJitter, borderColor: '#f39c12', yAxisID: 'y1' }
    ]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    scales: {
      y: { type: 'linear', position: 'left', title: { display: true, text: '丢包率 %' } },
      y1: { type: 'linear', position: 'right', title: { display: true, text: '抖动 ms' } }
    }
  }
});
</script>
</body>
</html>
EOF

    echo -e "\n${GREEN}✅ HTML报告已生成: ${html_file}${NC}"
    echo "浏览器打开即可查看图表，数据可直接用于内核调优分析"
}

# 执行一轮完整测试
one_round(){
    init_run
    case $SELECT_MODE in
        1) run_batch_test tcp ;;
        2) run_batch_test udp ;;
        3)
            run_batch_test tcp
            sleep 2
            run_batch_test udp
        ;;
    esac
    print_summary
    gen_html_report "${SUMMARY_CSV}" "${RUN_ID}"
}

# 测试主循环
start_test(){
    if ! input_params;then return;fi
    
    while true;do
        one_round
        if [ $LOOP_MODE -ne 1 ];then break;fi
        echo -e "\n${BLUE}等待 ${LOOP_INTERVAL}s 后开启下一轮测试...${NC}"
        sleep ${LOOP_INTERVAL}
    done
    read -p "按回车返回主菜单..."
}

# 生成历史报告
gen_report(){
    clear
    echo -e "${CYAN}=========== 历史测试报告生成 ===========${NC}"
    if [ ! -d "${LOG_ROOT}" ];then
        echo -e "${RED}未找到任何测试日志${NC}"
        read -p "按回车返回菜单..."
        return
    fi

    echo "已有的测试记录:"
    ls "${LOG_ROOT}"
    echo -n "输入run_id查看详情 (回车默认最新一条): "
    read rid

    if [ -z "$rid" ];then
        rid=$(ls "${LOG_ROOT}" | sort | tail -1)
    fi

    csv="${LOG_ROOT}/${rid}/summary_all.csv"
    if [ ! -f "$csv" ];then
        echo -e "${RED}该记录无汇总数据文件${NC}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "\n${CYAN}===== 测试报告: ${rid} =====${NC}"
    column -t -s ',' "$csv" | sort -t',' -k3 -n
    gen_html_report "$csv" "$rid"
    echo -e "\n原始文件: $csv"
    read -p "按回车返回主菜单..."
}

# 程序主入口
main(){
    check_deps
    while true;do
        show_menu
        read -r opt
        case $opt in
            1) SELECT_MODE=1; start_test ;;
            2) SELECT_MODE=2; start_test ;;
            3) SELECT_MODE=3; start_test ;;
            4) gen_report ;;
            0) echo -e "${GREEN}已退出脚本${NC}"; exit 0 ;;
            *) 
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
            ;;
        esac
    done
}

main
