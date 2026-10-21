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
declare -A PORT_STATUS
declare -a SERVER_PIDS=()

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
    echo -e "  ${GREEN}4${NC} | 读取历史日志，生成汇总报告"
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
    PORT_STATUS=()
}

# 单端口测试（带重试）
test_single_port(){
    local port="$1"
    local mode="$2"
    local ret=1
    local try=0
    local log_raw="${LOG_DIR}/${mode}/port_${port}.log"
    local log_json="${LOG_DIR}/${mode}/port_${port}.json"
    local extra_args=""

    if [ "$mode" = "udp" ];then
        extra_args="-u -b ${PORT_BAND}"
    elif [ -n "$PORT_BAND" ];then
        extra_args="-b ${PORT_BAND}"
    fi

    while [ $try -le $RETRY_TIMES ];do
        set +e
        timeout $((TEST_DURATION + 8)) iperf3 -c "${SERVER_IP}" -p "${port}" -t "${TEST_DURATION}" \
            -i 0 -P "${THREAD_PER_PORT}" ${extra_args} -J --logfile "${log_raw}" > "${log_json}" 2>/dev/null
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
    local loss_pct="-"
    local jitter_ms="-"

    if [ $ret -eq 124 ];then
        status="timeout"
    elif [ $ret -eq 0 ] && [ -f "${log_json}" ] && jq -r '.end' "${log_json}" &>/dev/null;then
        status="ok"
        tx_bps=$(jq -r '.end.sum_sent.bits_per_second // 0' "${log_json}")
        rx_bps=$(jq -r '.end.sum_receiver.bits_per_second // 0' "${log_json}")
        tx_mbps=$(echo "scale=2; $tx_bps / 1000000" | bc -l)
        rx_mbps=$(echo "scale=2; $rx_bps / 1000000" | bc -l)
        if [ "$mode" = "udp" ];then
            loss_pct=$(jq -r '.end.sum_receiver.loss_percent // 0' "${log_json}")
            jitter_ms=$(jq -r '.end.sum_receiver.jitter_ms // 0' "${log_json}")
        fi
    fi

    PORT_STATUS["${mode}_${port}"]="$status"
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

# 输出本轮结果汇总
print_summary(){
    echo -e "\n${CYAN}==================== 本轮测试结果 ====================${NC}"
    local ok=0 timeout=0 err=0

    for ((i=0; i<PORT_COUNT; i++));do
        port=$(( BASE_PORT + i ))
        for m in tcp udp;do
            if [ $SELECT_MODE -eq 1 ] && [ "$m" = "udp" ];then continue;fi
            if [ $SELECT_MODE -eq 2 ] && [ "$m" = "tcp" ];then continue;fi
            key="${m}_${port}"
            s="${PORT_STATUS[$key]:-error}"
            case $s in
                ok) ok=$((ok+1)) ;;
                timeout)
                    timeout=$((timeout+1))
                    echo -e "${YELLOW}[超时] ${m^^} 端口 $port${NC}"
                ;;
                error)
                    err=$((err+1))
                    echo -e "${RED}[异常] ${m^^} 端口 $port${NC}"
                ;;
            esac
        done
    done

    echo -e "\n${GREEN}✅ 正常: $ok  | ${YELLOW}⏱️ 超时: $timeout | ${RED}❌ 异常: $err${NC}"
    echo -e "日志目录: ${LOG_DIR}"
    echo -e "汇总文件: ${SUMMARY_CSV}"
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
    column -t -s ',' "$csv"
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
