#!/usr/bin/env bash
#
# auto_tune_tcp_v2.sh
# 基于 BDP + iperf3 多方向/多并发重复测试，选择较小且性能接近峰值的 TCP 缓冲区上限。
#
# 设计原则：
#   1. 测试期间临时修改 sysctl，异常/中断自动恢复。
#   2. 不覆盖 /etc/sysctl.conf，只写独立的 /etc/sysctl.d 配置。
#   3. 保留 tcp_rmem/tcp_wmem 的 min/default，仅调整 max。
#   4. 分别测试 forward、reverse、bidir，并对每个候选重复采样。
#   5. 各方向吞吐达到该方向最佳值阈值后，优先选择低重传、较小缓冲区。
#
# 服务端示例：
#   iperf3 -s
#
# 客户端示例：
#   sudo bash auto_tune_tcp_v2.sh \
#     --target 203.0.113.10 \
#     --local-bw 10000 \
#     --remote-bw 10000 \
#     --parallel 4 \
#     --apply

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
VERSION="2.0.0"

# ---------- 默认配置 ----------
TARGET=""
LOCAL_BW_Mbps=""
REMOTE_BW_Mbps=""
RTT_MS=""
PORT=5201
PARALLEL=4
DURATION=10
OMIT=2
REPEATS=3
PING_COUNT=10
CONNECT_TIMEOUT_MS=5000
MODES_CSV="forward,reverse,bidir"
MAX_BUFFER_MIB=512
THRESHOLD_PERCENT=98
CONFIG_FILE="/etc/sysctl.d/90-auto-tune-tcp.conf"
LOG_BASE_DIR="/var/log/auto-tune-tcp"
BIND_ADDRESS=""
IP_VERSION=""
APPLY_MODE="ask"       # ask | yes | no
INSTALL_DEPS=0
SETTLE_SECONDS=1

# ---------- 颜色 ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'
    C_BLUE=$'\033[1;34m'
    C_CYAN=$'\033[1;36m'
    C_RESET=$'\033[0m'
else
    C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_CYAN="" C_RESET=""
fi

info()  { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：
  sudo bash auto_tune_tcp_v2.sh [选项]

必要参数（缺省时会交互询问）：
  --target HOST             iperf3 服务端地址、IPv4、IPv6 或主机名
  --local-bw Mbps           本地链路带宽，单位 Mbps
  --remote-bw Mbps          对端链路带宽，单位 Mbps

测试参数：
  --rtt-ms MS               手动指定 RTT；未指定时通过 ping 测量
  --port PORT               iperf3 端口，默认 5201
  --parallel N              并发 TCP 流数，默认 4
  --duration SEC            每轮有效测试时长，默认 10 秒
  --omit SEC                预热并忽略的时长，默认 2 秒
  --repeats N               每个候选每种方向重复次数，默认 3
  --modes LIST              forward,reverse,bidir 的逗号组合，默认全部
  --max-buffer-mib MiB      候选缓冲区硬上限，默认 512 MiB
  --threshold PERCENT       接近最佳吞吐的阈值，默认 98
  --ping-count N            RTT 测量包数，默认 10
  --connect-timeout MS      iperf3 连接超时，默认 5000 ms
  --bind ADDRESS            传给 iperf3 -B 的本地地址
  -4                        强制 IPv4
  -6                        强制 IPv6

生效与输出：
  --apply                   自动写入并应用最终配置
  --no-apply                只测试和推荐，不写永久配置
  --config FILE             配置文件路径，默认 /etc/sysctl.d/90-auto-tune-tcp.conf
  --log-dir DIR             报告目录，默认 /var/log/auto-tune-tcp
  --install-deps            尝试使用系统包管理器安装缺失依赖
  -h, --help                显示帮助
  -V, --version             显示版本

示例：
  sudo bash auto_tune_tcp_v2.sh \
    --target 192.0.2.10 --local-bw 1000 --remote-bw 1000

  sudo bash auto_tune_tcp_v2.sh \
    --target 2001:db8::10 -6 --local-bw 10000 --remote-bw 10000 \
    --parallel 8 --duration 15 --repeats 3 --apply
EOF
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_positive_number() {
    [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] &&
        awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

ceil_number() {
    awk -v value="$1" 'BEGIN {
        integer = int(value)
        print (value > integer) ? integer + 1 : integer
    }'
}

max_number() {
    awk -v a="$1" -v b="$2" 'BEGIN { print (a > b) ? a : b }'
}

join_by() {
    local delimiter=$1
    shift
    local output="" item
    for item in "$@"; do
        output+="${output:+$delimiter}$item"
    done
    printf '%s' "$output"
}

mib_to_bytes() {
    awk -v mib="$1" 'BEGIN { printf "%.0f", mib * 1024 * 1024 }'
}

bytes_to_mib_ceil() {
    awk -v bytes="$1" 'BEGIN {
        value = bytes / 1048576
        integer = int(value)
        print (value > integer) ? integer + 1 : integer
    }'
}

prompt_positive_integer() {
    local prompt=$1
    local value=""
    while true; do
        read -r -p "$prompt" value || die "无法读取输入。"
        if is_positive_integer "$value"; then
            printf '%s' "$value"
            return 0
        fi
        warn "请输入有效的正整数。"
    done
}

parse_args() {
    while (($#)); do
        case "$1" in
            --target)
                (($# >= 2)) || die "--target 缺少参数"
                TARGET=$2; shift 2 ;;
            --local-bw)
                (($# >= 2)) || die "--local-bw 缺少参数"
                LOCAL_BW_Mbps=$2; shift 2 ;;
            --remote-bw)
                (($# >= 2)) || die "--remote-bw 缺少参数"
                REMOTE_BW_Mbps=$2; shift 2 ;;
            --rtt-ms)
                (($# >= 2)) || die "--rtt-ms 缺少参数"
                RTT_MS=$2; shift 2 ;;
            --port)
                (($# >= 2)) || die "--port 缺少参数"
                PORT=$2; shift 2 ;;
            --parallel)
                (($# >= 2)) || die "--parallel 缺少参数"
                PARALLEL=$2; shift 2 ;;
            --duration)
                (($# >= 2)) || die "--duration 缺少参数"
                DURATION=$2; shift 2 ;;
            --omit)
                (($# >= 2)) || die "--omit 缺少参数"
                OMIT=$2; shift 2 ;;
            --repeats)
                (($# >= 2)) || die "--repeats 缺少参数"
                REPEATS=$2; shift 2 ;;
            --modes)
                (($# >= 2)) || die "--modes 缺少参数"
                MODES_CSV=$2; shift 2 ;;
            --max-buffer-mib)
                (($# >= 2)) || die "--max-buffer-mib 缺少参数"
                MAX_BUFFER_MIB=$2; shift 2 ;;
            --threshold)
                (($# >= 2)) || die "--threshold 缺少参数"
                THRESHOLD_PERCENT=$2; shift 2 ;;
            --ping-count)
                (($# >= 2)) || die "--ping-count 缺少参数"
                PING_COUNT=$2; shift 2 ;;
            --connect-timeout)
                (($# >= 2)) || die "--connect-timeout 缺少参数"
                CONNECT_TIMEOUT_MS=$2; shift 2 ;;
            --bind)
                (($# >= 2)) || die "--bind 缺少参数"
                BIND_ADDRESS=$2; shift 2 ;;
            --config)
                (($# >= 2)) || die "--config 缺少参数"
                CONFIG_FILE=$2; shift 2 ;;
            --log-dir)
                (($# >= 2)) || die "--log-dir 缺少参数"
                LOG_BASE_DIR=$2; shift 2 ;;
            --apply)
                APPLY_MODE="yes"; shift ;;
            --no-apply)
                APPLY_MODE="no"; shift ;;
            --install-deps)
                INSTALL_DEPS=1; shift ;;
            -4)
                IP_VERSION="4"; shift ;;
            -6)
                IP_VERSION="6"; shift ;;
            -h|--help)
                usage; exit 0 ;;
            -V|--version)
                printf '%s %s\n' "$PROGRAM_NAME" "$VERSION"; exit 0 ;;
            --)
                shift; break ;;
            *)
                die "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
    done
}

install_dependencies() {
    local missing=("$@")
    ((${#missing[@]} > 0)) || return 0

    info "尝试安装缺失依赖：${missing[*]}"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 jq iputils-ping gawk coreutils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y iperf3 jq iputils gawk coreutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iperf3 jq iputils gawk coreutils
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install iperf3 jq iputils gawk coreutils
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm iperf3 jq iputils gawk coreutils
    else
        die "未识别到受支持的包管理器，请手动安装：iperf3、jq、ping、awk、sort。"
    fi
}

check_dependencies() {
    local required=(iperf3 jq ping awk sort sysctl mktemp grep sed date)
    local missing=()
    local command_name

    for command_name in "${required[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done

    if ((${#missing[@]} > 0)); then
        if ((INSTALL_DEPS)); then
            install_dependencies "${missing[@]}"
        else
            die "缺少依赖：${missing[*]}。安装后重试，或使用 --install-deps。"
        fi
    fi

    missing=()
    for command_name in "${required[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) || die "依赖安装后仍缺少：${missing[*]}"
}

validate_config() {
    [[ -n "$TARGET" ]] || {
        read -r -p "请输入 iperf3 服务端地址：" TARGET || die "无法读取目标地址。"
    }
    [[ -n "$TARGET" ]] || die "目标地址不能为空。"
    [[ "$TARGET" != *$'\n'* && "$TARGET" != *$'\r'* ]] || die "目标地址包含非法换行。"

    [[ -n "$LOCAL_BW_Mbps" ]] || LOCAL_BW_Mbps=$(prompt_positive_integer "请输入本地带宽（Mbps）：")
    [[ -n "$REMOTE_BW_Mbps" ]] || REMOTE_BW_Mbps=$(prompt_positive_integer "请输入测试端带宽（Mbps）：")

    is_positive_number "$LOCAL_BW_Mbps" || die "--local-bw 必须为正数。"
    is_positive_number "$REMOTE_BW_Mbps" || die "--remote-bw 必须为正数。"
    [[ -z "$RTT_MS" ]] || is_positive_number "$RTT_MS" || die "--rtt-ms 必须为正数。"

    local integer_name
    for integer_name in PORT PARALLEL DURATION REPEATS PING_COUNT CONNECT_TIMEOUT_MS MAX_BUFFER_MIB; do
        is_positive_integer "${!integer_name}" || die "$integer_name 必须为正整数。"
    done
    [[ "$OMIT" =~ ^[0-9]+$ ]] || die "OMIT 必须为非负整数。"

    ((PORT >= 1 && PORT <= 65535)) || die "端口必须在 1-65535 之间。"
    ((PARALLEL <= 128)) || die "并发流数过大；请使用不超过 128 的值。"
    ((REPEATS <= 20)) || die "重复次数过大；请使用不超过 20 的值。"
    ((MAX_BUFFER_MIB <= 16384)) || die "缓冲区上限过大；最大允许 16384 MiB。"

    is_positive_number "$THRESHOLD_PERCENT" || die "--threshold 必须为正数。"
    awk -v value="$THRESHOLD_PERCENT" 'BEGIN { exit !(value >= 50 && value <= 100) }' ||
        die "--threshold 必须在 50-100 之间。"

    case ",$MODES_CSV," in
        *",forward,"*|*",reverse,"*|*",bidir,"*) ;;
        *) die "--modes 至少包含 forward、reverse 或 bidir 之一。" ;;
    esac

    local token
    local normalized=""
    IFS=',' read -r -a requested_modes <<< "$MODES_CSV"
    for token in "${requested_modes[@]}"; do
        case "$token" in
            forward|reverse|bidir)
                [[ ",$normalized," == *",$token,"* ]] || normalized+="${normalized:+,}$token"
                ;;
            *) die "无效测试模式：$token" ;;
        esac
    done
    MODES_CSV=$normalized
}

# ---------- sysctl 状态 ----------
ORIG_TCP_WMEM=""
ORIG_TCP_RMEM=""
ORIG_CORE_WMEM_MAX=""
ORIG_CORE_RMEM_MAX=""
ORIG_MODERATE_RCVBUF=""
ORIG_WINDOW_SCALING=""
ORIG_WMEM_MIN="" ORIG_WMEM_DEFAULT="" ORIG_WMEM_MAX=""
ORIG_RMEM_MIN="" ORIG_RMEM_DEFAULT="" ORIG_RMEM_MAX=""
COMMITTED=0
SYSCTL_CAPTURED=0
WORK_DIR=""
RESULTS_CSV=""
SUMMARY_TSV=""
RUN_LOG=""

capture_sysctl_state() {
    ORIG_TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem)
    ORIG_TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)
    ORIG_CORE_WMEM_MAX=$(sysctl -n net.core.wmem_max)
    ORIG_CORE_RMEM_MAX=$(sysctl -n net.core.rmem_max)
    ORIG_MODERATE_RCVBUF=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)
    ORIG_WINDOW_SCALING=$(sysctl -n net.ipv4.tcp_window_scaling)

    IFS=' 	' read -r ORIG_WMEM_MIN ORIG_WMEM_DEFAULT ORIG_WMEM_MAX <<< "$ORIG_TCP_WMEM"
    IFS=' 	' read -r ORIG_RMEM_MIN ORIG_RMEM_DEFAULT ORIG_RMEM_MAX <<< "$ORIG_TCP_RMEM"

    [[ -n "$ORIG_WMEM_MAX" && -n "$ORIG_RMEM_MAX" ]] || die "无法读取 TCP sysctl 参数。"
    SYSCTL_CAPTURED=1
}

restore_sysctl_state() {
    ((SYSCTL_CAPTURED)) || return 0

    sysctl -q -w "net.core.wmem_max=$ORIG_CORE_WMEM_MAX" >/dev/null || true
    sysctl -q -w "net.core.rmem_max=$ORIG_CORE_RMEM_MAX" >/dev/null || true
    sysctl -q -w "net.ipv4.tcp_wmem=$ORIG_TCP_WMEM" >/dev/null || true
    sysctl -q -w "net.ipv4.tcp_rmem=$ORIG_TCP_RMEM" >/dev/null || true
    sysctl -q -w "net.ipv4.tcp_moderate_rcvbuf=$ORIG_MODERATE_RCVBUF" >/dev/null || true
    sysctl -q -w "net.ipv4.tcp_window_scaling=$ORIG_WINDOW_SCALING" >/dev/null || true
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP

    if ((COMMITTED == 0)); then
        restore_sysctl_state
        if ((SYSCTL_CAPTURED)); then
            warn "未提交永久配置，已恢复原始 sysctl 参数。"
        fi
    fi

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        info "测试报告保存在：$WORK_DIR"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM HUP

apply_candidate_sysctl() {
    local candidate_bytes=$1
    local core_wmem_target core_rmem_target

    core_wmem_target=$(max_number "$ORIG_CORE_WMEM_MAX" "$candidate_bytes")
    core_rmem_target=$(max_number "$ORIG_CORE_RMEM_MAX" "$candidate_bytes")

    # core 上限先升高，避免 tcp_wmem 的 max 被 net.core.wmem_max 限制。
    sysctl -q -w "net.core.wmem_max=$core_wmem_target" >/dev/null
    sysctl -q -w "net.core.rmem_max=$core_rmem_target" >/dev/null
    sysctl -q -w "net.ipv4.tcp_wmem=$ORIG_WMEM_MIN $ORIG_WMEM_DEFAULT $candidate_bytes" >/dev/null
    sysctl -q -w "net.ipv4.tcp_rmem=$ORIG_RMEM_MIN $ORIG_RMEM_DEFAULT $candidate_bytes" >/dev/null
    sysctl -q -w "net.ipv4.tcp_moderate_rcvbuf=1" >/dev/null
    sysctl -q -w "net.ipv4.tcp_window_scaling=1" >/dev/null
}

# ---------- RTT / BDP ----------
measure_rtt() {
    if [[ -n "$RTT_MS" ]]; then
        info "使用手动指定 RTT：${RTT_MS} ms"
        return 0
    fi

    local -a ping_command=(ping -n -c "$PING_COUNT")
    local ping_output parsed_rtt

    if [[ "$IP_VERSION" == "4" ]]; then
        ping_command+=(-4)
    elif [[ "$IP_VERSION" == "6" ]]; then
        ping_command+=(-6)
    fi

    info "测量到 $TARGET 的 RTT（$PING_COUNT 个样本）..."
    if ! ping_output=$("${ping_command[@]}" "$TARGET" 2>&1); then
        printf '%s\n' "$ping_output" >> "$RUN_LOG"
        if [[ -t 0 ]]; then
            warn "ping 失败或被防火墙阻断。"
            while true; do
                read -r -p "请手动输入 RTT（ms）：" RTT_MS || die "无法获取 RTT。"
                is_positive_number "$RTT_MS" && break
                warn "请输入有效的正数。"
            done
            return 0
        fi
        die "无法通过 ping 获取 RTT；请使用 --rtt-ms 手动指定。"
    fi

    printf '%s\n' "$ping_output" >> "$RUN_LOG"
    parsed_rtt=$(awk -F'=' '
        /(^|[[:space:]])(rtt|round-trip)[[:space:]].*=/ {
            value=$2
            gsub(/[[:space:]]*ms[[:space:]]*/, "", value)
            split(value, parts, "/")
            if (parts[2] ~ /^[0-9.]+$/) print parts[2]
        }
    ' <<< "$ping_output" | tail -n 1)

    if ! is_positive_number "${parsed_rtt:-}"; then
        die "无法解析 ping RTT；请使用 --rtt-ms 手动指定。"
    fi

    RTT_MS=$parsed_rtt
    ok "平均 RTT：${RTT_MS} ms"
}

# ---------- iperf3 ----------
IPERF_HELP=""
IPERF_HAS_CONNECT_TIMEOUT=0
IPERF_HAS_BIDIR=0

inspect_iperf_capabilities() {
    IPERF_HELP=$(iperf3 --help 2>&1 || true)
    grep -q -- '--connect-timeout' <<< "$IPERF_HELP" && IPERF_HAS_CONNECT_TIMEOUT=1
    grep -q -- '--bidir' <<< "$IPERF_HELP" && IPERF_HAS_BIDIR=1

    if [[ ",$MODES_CSV," == *",bidir,"* ]] && ((IPERF_HAS_BIDIR == 0)); then
        warn "当前 iperf3 不支持 --bidir，将跳过 bidir 模式。"
        MODES_CSV=$(sed -E 's/(^|,)bidir(,|$)/\1\2/; s/^,//; s/,$//; s/,,+/,/g' <<< "$MODES_CSV")
        [[ -n "$MODES_CSV" ]] || die "当前 iperf3 不支持唯一请求的 bidir 模式。"
    fi
}

build_iperf_command() {
    local mode=$1
    IPERF_COMMAND=(
        iperf3 -c "$TARGET" -p "$PORT"
        -P "$PARALLEL"
        -t "$DURATION"
        -O "$OMIT"
        --json
    )

    ((IPERF_HAS_CONNECT_TIMEOUT)) && IPERF_COMMAND+=(--connect-timeout "$CONNECT_TIMEOUT_MS")
    [[ -n "$BIND_ADDRESS" ]] && IPERF_COMMAND+=(-B "$BIND_ADDRESS")
    [[ "$IP_VERSION" == "4" ]] && IPERF_COMMAND+=(-4)
    [[ "$IP_VERSION" == "6" ]] && IPERF_COMMAND+=(-6)

    case "$mode" in
        forward) ;;
        reverse) IPERF_COMMAND+=(-R) ;;
        bidir)   IPERF_COMMAND+=(--bidir) ;;
        *)       return 1 ;;
    esac
}

display_command() {
    local arg
    printf '命令：' >> "$RUN_LOG"
    for arg in "$@"; do
        printf ' %q' "$arg" >> "$RUN_LOG"
    done
    printf '\n' >> "$RUN_LOG"
}

run_iperf_test() {
    local candidate_mib=$1
    local repeat_no=$2
    local mode=$3
    local json_file error_file
    local throughput_bps retransmits received_bytes speed_mbps retrans_per_gib

    json_file="$WORK_DIR/iperf_${candidate_mib}MiB_r${repeat_no}_${mode}.json"
    error_file="$WORK_DIR/iperf_${candidate_mib}MiB_r${repeat_no}_${mode}.stderr"

    build_iperf_command "$mode"
    display_command "${IPERF_COMMAND[@]}"

    if ! "${IPERF_COMMAND[@]}" >"$json_file" 2>"$error_file"; then
        warn "${candidate_mib} MiB / 第 ${repeat_no} 次 / ${mode}：iperf3 执行失败。"
        sed 's/^/  /' "$error_file" >&2 || true
        printf '%s,%s,%s,0,0,0,0,0,failed\n' \
            "$candidate_mib" "$repeat_no" "$mode" >> "$RESULTS_CSV"
        return 1
    fi

    if ! jq -e . "$json_file" >/dev/null 2>&1; then
        warn "${candidate_mib} MiB / 第 ${repeat_no} 次 / ${mode}：返回内容不是有效 JSON。"
        printf '%s,%s,%s,0,0,0,0,0,invalid_json\n' \
            "$candidate_mib" "$repeat_no" "$mode" >> "$RESULTS_CSV"
        return 1
    fi

    local iperf_error
    iperf_error=$(jq -r '.error // empty' "$json_file")
    if [[ -n "$iperf_error" ]]; then
        warn "${candidate_mib} MiB / 第 ${repeat_no} 次 / ${mode}：$iperf_error"
        printf '%s,%s,%s,0,0,0,0,0,iperf_error\n' \
            "$candidate_mib" "$repeat_no" "$mode" >> "$RESULTS_CSV"
        return 1
    fi

    # 对 bidir，累加两个方向所有 sum_received* 项；普通测试只有一个。
    throughput_bps=$(jq -r '
        ([.end | to_entries[]
          | select(.key | test("^sum_received"))
          | (.value.bits_per_second // empty)] | add)
        // .end.sum.bits_per_second
        // 0
    ' "$json_file")

    received_bytes=$(jq -r '
        ([.end | to_entries[]
          | select(.key | test("^sum_received"))
          | (.value.bytes // empty)] | add)
        // .end.sum.bytes
        // 0
    ' "$json_file")

    retransmits=$(jq -r '
        ([.end | to_entries[]
          | select(.key | test("^sum_sent"))
          | (.value.retransmits // 0)] | add)
        // ([.end.streams[]?.sender.retransmits // 0] | add)
        // 0
    ' "$json_file")

    throughput_bps=$(awk -v value="$throughput_bps" 'BEGIN { printf "%.0f", value + 0 }')
    received_bytes=$(awk -v value="$received_bytes" 'BEGIN { printf "%.0f", value + 0 }')
    retransmits=$(awk -v value="$retransmits" 'BEGIN { printf "%.0f", value + 0 }')

    if ((throughput_bps <= 0 || received_bytes <= 0)); then
        warn "${candidate_mib} MiB / 第 ${repeat_no} 次 / ${mode}：吞吐结果为 0。"
        printf '%s,%s,%s,0,0,%s,%s,0,zero_result\n' \
            "$candidate_mib" "$repeat_no" "$mode" "$retransmits" "$received_bytes" >> "$RESULTS_CSV"
        return 1
    fi

    speed_mbps=$(awk -v bps="$throughput_bps" 'BEGIN { printf "%.2f", bps / 1000000 }')
    retrans_per_gib=$(awk -v retrans="$retransmits" -v bytes="$received_bytes" 'BEGIN {
        gib = bytes / 1073741824
        if (gib > 0) printf "%.6f", retrans / gib; else print 0
    }')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,ok\n' \
        "$candidate_mib" "$repeat_no" "$mode" "$throughput_bps" "$speed_mbps" \
        "$retransmits" "$received_bytes" "$retrans_per_gib" >> "$RESULTS_CSV"

    printf '  %-7s %10s Mbps  重传/GiB: %10s\n' "$mode" "$speed_mbps" "$retrans_per_gib"
    return 0
}

preflight_iperf() {
    local saved_duration=$DURATION
    local saved_omit=$OMIT
    local saved_parallel=$PARALLEL
    local preflight_json="$WORK_DIR/preflight.json"
    local preflight_err="$WORK_DIR/preflight.stderr"

    DURATION=1
    OMIT=0
    PARALLEL=1
    build_iperf_command forward
    DURATION=$saved_duration
    OMIT=$saved_omit
    PARALLEL=$saved_parallel

    info "检查 iperf3 服务端连通性..."
    if ! "${IPERF_COMMAND[@]}" >"$preflight_json" 2>"$preflight_err"; then
        sed 's/^/  /' "$preflight_err" >&2 || true
        die "无法连接 iperf3 服务端 $TARGET:$PORT。请先在对端运行：iperf3 -s -p $PORT"
    fi
    if ! jq -e '.error == null and (.end != null)' "$preflight_json" >/dev/null 2>&1; then
        local message
        message=$(jq -r '.error // "未知错误"' "$preflight_json" 2>/dev/null || printf '无效 JSON')
        die "iperf3 预检查失败：$message"
    fi
    ok "iperf3 服务端可用。"
}

median_from_stream() {
    sort -n | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) exit 1
            if (NR % 2 == 1) printf "%.6f", values[(NR + 1) / 2]
            else printf "%.6f", (values[NR / 2] + values[NR / 2 + 1]) / 2
        }
    '
}

get_median_bps() {
    local candidate=$1
    local mode=$2
    awk -F',' -v candidate="$candidate" -v mode="$mode" '
        NR > 1 && $1 == candidate && $3 == mode && $9 == "ok" { print $4 }
    ' "$RESULTS_CSV" | median_from_stream
}

get_success_count() {
    local candidate=$1
    local mode=$2
    awk -F',' -v candidate="$candidate" -v mode="$mode" '
        NR > 1 && $1 == candidate && $3 == mode && $9 == "ok" { count++ }
        END { print count + 0 }
    ' "$RESULTS_CSV"
}

get_retrans_per_gib() {
    local candidate=$1
    awk -F',' -v candidate="$candidate" '
        NR > 1 && $1 == candidate && $9 == "ok" {
            retrans += $6
            bytes += $7
        }
        END {
            gib = bytes / 1073741824
            if (gib > 0) printf "%.6f", retrans / gib
            else print "999999999999"
        }
    ' "$RESULTS_CSV"
}

# ---------- 主流程 ----------
parse_args "$@"

[[ "$(uname -s)" == "Linux" ]] || die "此脚本只支持 Linux。"
((EUID == 0)) || die "需要 root 权限，请使用 sudo 运行。"

check_dependencies
validate_config
inspect_iperf_capabilities
capture_sysctl_state

RUN_ID=$(date '+%Y%m%d-%H%M%S')
WORK_DIR="$LOG_BASE_DIR/$RUN_ID"
mkdir -p "$WORK_DIR"
chmod 0750 "$WORK_DIR"
RESULTS_CSV="$WORK_DIR/results.csv"
SUMMARY_TSV="$WORK_DIR/summary.tsv"
RUN_LOG="$WORK_DIR/run.log"

printf 'candidate_mib,repeat,mode,throughput_bps,throughput_mbps,retransmits,received_bytes,retrans_per_gib,status\n' > "$RESULTS_CSV"
{
    printf 'program=%s\n' "$PROGRAM_NAME"
    printf 'version=%s\n' "$VERSION"
    printf 'date=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'iperf3=%s\n' "$(iperf3 --version 2>&1 | head -n 1)"
    printf 'target=%s\n' "$TARGET"
    printf 'port=%s\n' "$PORT"
    printf 'parallel=%s\n' "$PARALLEL"
    printf 'duration=%s\n' "$DURATION"
    printf 'omit=%s\n' "$OMIT"
    printf 'repeats=%s\n' "$REPEATS"
    printf 'modes=%s\n' "$MODES_CSV"
    printf 'original_tcp_wmem=%s\n' "$ORIG_TCP_WMEM"
    printf 'original_tcp_rmem=%s\n' "$ORIG_TCP_RMEM"
    printf 'original_core_wmem_max=%s\n' "$ORIG_CORE_WMEM_MAX"
    printf 'original_core_rmem_max=%s\n' "$ORIG_CORE_RMEM_MAX"
    printf 'congestion_control=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
    printf 'default_qdisc=%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
} > "$RUN_LOG"

measure_rtt
preflight_iperf
warn "本脚本只修改当前客户端的 sysctl；若需要两端对称优化，请在对端也独立测试并应用。"

BOTTLENECK_BW_Mbps=$(awk -v local_bw="$LOCAL_BW_Mbps" -v remote_bw="$REMOTE_BW_Mbps" \
    'BEGIN { print (local_bw < remote_bw) ? local_bw : remote_bw }')
BDP_BYTES=$(awk -v bw="$BOTTLENECK_BW_Mbps" -v rtt="$RTT_MS" \
    'BEGIN { printf "%.0f", bw * 1000000 * (rtt / 1000) / 8 }')
BDP_MIB=$(awk -v bytes="$BDP_BYTES" 'BEGIN { printf "%.3f", bytes / 1048576 }')

info "瓶颈带宽：${BOTTLENECK_BW_Mbps} Mbps"
info "理论 BDP：${BDP_MIB} MiB（${BDP_BYTES} 字节）"

# 候选：1 MiB、当前最大值、0.5/1/2/4/8 × BDP；去重并受硬上限约束。
declare -a RAW_CANDIDATES=(1)
CURRENT_MAX_BYTES=$(max_number "$ORIG_WMEM_MAX" "$ORIG_RMEM_MAX")
CURRENT_MAX_MIB=$(bytes_to_mib_ceil "$CURRENT_MAX_BYTES")
RAW_CANDIDATES+=("$CURRENT_MAX_MIB")

for multiplier in 0.5 1 2 4 8; do
    value=$(awk -v bdp="$BDP_MIB" -v multiplier="$multiplier" 'BEGIN {
        value = bdp * multiplier
        if (value < 1) value = 1
        integer = int(value)
        print (value > integer) ? integer + 1 : integer
    }')
    RAW_CANDIDATES+=("$value")
done

# 如果最高倍数被截断，显式加入用户上限，便于判断是否仍受缓冲区限制。
BDP_X8_MIB=$(ceil_number "$(awk -v bdp="$BDP_MIB" 'BEGIN { print bdp * 8 }')")
((BDP_X8_MIB > MAX_BUFFER_MIB)) && RAW_CANDIDATES+=("$MAX_BUFFER_MIB")

mapfile -t CANDIDATES < <(
    printf '%s\n' "${RAW_CANDIDATES[@]}" |
        awk -v max="$MAX_BUFFER_MIB" '$1 >= 1 { if ($1 > max) $1=max; print int($1) }' |
        sort -n -u
)

((${#CANDIDATES[@]} > 0)) || die "未生成有效候选值。"

CANDIDATE_LIST=$(join_by ' ' "${CANDIDATES[@]}")
printf '%s\n' "候选缓冲区：${CANDIDATE_LIST} MiB" | tee -a "$RUN_LOG"
printf '测试模式：%s；每个候选每种模式重复 %s 次。\n' "$MODES_CSV" "$REPEATS" | tee -a "$RUN_LOG"

IFS=',' read -r -a MODES <<< "$MODES_CSV"
FAILED_TESTS=0
TOTAL_TESTS=0

for ((repeat_no=1; repeat_no<=REPEATS; repeat_no++)); do
    # 每轮改变顺序，降低固定测试顺序对结果的影响。
    if command -v shuf >/dev/null 2>&1; then
        mapfile -t ROUND_CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | shuf)
    else
        ROUND_CANDIDATES=()
        candidate_count=${#CANDIDATES[@]}
        for ((index=0; index<candidate_count; index++)); do
            rotated_index=$(((index + repeat_no - 1) % candidate_count))
            ROUND_CANDIDATES+=("${CANDIDATES[$rotated_index]}")
        done
    fi

    info "开始第 $repeat_no/$REPEATS 轮采样。"
    for candidate_mib in "${ROUND_CANDIDATES[@]}"; do
        candidate_bytes=$(mib_to_bytes "$candidate_mib")
        apply_candidate_sysctl "$candidate_bytes"
        sleep "$SETTLE_SECONDS"

        printf '\n%s缓冲区 %s MiB（第 %s 次）%s\n' \
            "$C_BLUE" "$candidate_mib" "$repeat_no" "$C_RESET"

        for mode in "${MODES[@]}"; do
            ((TOTAL_TESTS += 1))
            if ! run_iperf_test "$candidate_mib" "$repeat_no" "$mode"; then
                ((FAILED_TESTS += 1))
            fi
        done
    done
done

if ((FAILED_TESTS == TOTAL_TESTS)); then
    die "全部测试失败，无法生成推荐值。"
fi
if ((FAILED_TESTS > 0)); then
    warn "$TOTAL_TESTS 个测试中有 $FAILED_TESTS 个失败；推荐结果只使用成功样本。"
fi

# 聚合每个候选、每个模式的吞吐中位数。
printf 'candidate_mib' > "$SUMMARY_TSV"
for mode in "${MODES[@]}"; do
    printf '\t%s_median_bps\t%s_successes' "$mode" "$mode" >> "$SUMMARY_TSV"
done
printf '\tretrans_per_gib\tmin_ratio_percent\tqualified\n' >> "$SUMMARY_TSV"

declare -A BEST_MODE_BPS=()
for mode in "${MODES[@]}"; do
    best=0
    for candidate_mib in "${CANDIDATES[@]}"; do
        median=$(get_median_bps "$candidate_mib" "$mode" 2>/dev/null || printf '0')
        awk -v median="$median" -v best="$best" 'BEGIN { exit !(median > best) }' && best=$median || true
    done
    BEST_MODE_BPS[$mode]=$best
    awk -v best="$best" 'BEGIN { exit !(best > 0) }' || die "模式 $mode 没有有效测试结果。"
done

BEST_CANDIDATE=""
BEST_RETRANS=""
BEST_MIN_RATIO=""
BEST_QUALIFIED=0

for candidate_mib in "${CANDIDATES[@]}"; do
    row="$candidate_mib"
    min_ratio=1000000
    qualified=1

    for mode in "${MODES[@]}"; do
        median=$(get_median_bps "$candidate_mib" "$mode" 2>/dev/null || printf '0')
        successes=$(get_success_count "$candidate_mib" "$mode")
        row+=$'\t'"$median"$'\t'"$successes"

        ratio=$(awk -v median="$median" -v best="${BEST_MODE_BPS[$mode]}" 'BEGIN {
            if (best > 0) printf "%.6f", median / best * 100
            else print 0
        }')
        min_ratio=$(awk -v current="$min_ratio" -v ratio="$ratio" \
            'BEGIN { print (ratio < current) ? ratio : current }')

        awk -v ratio="$ratio" -v threshold="$THRESHOLD_PERCENT" \
            'BEGIN { exit !(ratio >= threshold) }' || qualified=0
    done

    retrans_per_gib=$(get_retrans_per_gib "$candidate_mib")
    row+=$'\t'"$retrans_per_gib"$'\t'"$min_ratio"$'\t'"$qualified"
    printf '%s\n' "$row" >> "$SUMMARY_TSV"

    # 选择规则：
    # 1) 优先所有方向均达到阈值的候选；
    # 2) 同为合格候选时，重传/GiB 更低者优先；
    # 3) 重传相同时，较小缓冲区优先。
    # 若无候选达标，则优先最差方向相对吞吐最高者。
    if [[ -z "$BEST_CANDIDATE" ]]; then
        BEST_CANDIDATE=$candidate_mib
        BEST_RETRANS=$retrans_per_gib
        BEST_MIN_RATIO=$min_ratio
        BEST_QUALIFIED=$qualified
        continue
    fi

    choose=0
    if ((qualified > BEST_QUALIFIED)); then
        choose=1
    elif ((qualified == BEST_QUALIFIED)); then
        if ((qualified == 1)); then
            if awk -v current="$retrans_per_gib" -v best="$BEST_RETRANS" \
                'BEGIN { exit !(current < best) }'; then
                choose=1
            elif awk -v current="$retrans_per_gib" -v best="$BEST_RETRANS" \
                'BEGIN { exit !(current == best) }' && ((candidate_mib < BEST_CANDIDATE)); then
                choose=1
            fi
        else
            if awk -v current="$min_ratio" -v best="$BEST_MIN_RATIO" \
                'BEGIN { exit !(current > best) }'; then
                choose=1
            elif awk -v current="$min_ratio" -v best="$BEST_MIN_RATIO" \
                'BEGIN { exit !(current == best) }'; then
                if awk -v current="$retrans_per_gib" -v best="$BEST_RETRANS" \
                    'BEGIN { exit !(current < best) }'; then
                    choose=1
                elif awk -v current="$retrans_per_gib" -v best="$BEST_RETRANS" \
                    'BEGIN { exit !(current == best) }' && ((candidate_mib < BEST_CANDIDATE)); then
                    choose=1
                fi
            fi
        fi
    fi

    if ((choose)); then
        BEST_CANDIDATE=$candidate_mib
        BEST_RETRANS=$retrans_per_gib
        BEST_MIN_RATIO=$min_ratio
        BEST_QUALIFIED=$qualified
    fi
done

printf '\n%s聚合结果%s\n' "$C_CYAN" "$C_RESET"
printf '%-10s' '缓冲MiB'
for mode in "${MODES[@]}"; do
    printf ' %-15s' "${mode}(Mbps)"
done
printf ' %-14s %-12s %s\n' '重传/GiB' '最低相对%' '达标'

while IFS=$'\t' read -r -a fields; do
    [[ "${fields[0]}" == "candidate_mib" ]] && continue
    index=0
    printf '%-10s' "${fields[$index]}"
    ((index += 1))
    for _mode in "${MODES[@]}"; do
        bps=${fields[$index]}; ((index += 1))
        _successes=${fields[$index]}; ((index += 1))
        mbps=$(awk -v bps="$bps" 'BEGIN { printf "%.2f", bps / 1000000 }')
        printf ' %-15s' "$mbps"
    done
    _retrans=${fields[$index]}; ((index += 1))
    _ratio=${fields[$index]}; ((index += 1))
    _qualified=${fields[$index]}
    [[ "$_qualified" == "1" ]] && qualified_text="是" || qualified_text="否"
    printf ' %-14.3f %-12.2f %s\n' "$_retrans" "$_ratio" "$qualified_text"
done < "$SUMMARY_TSV"

if ((BEST_QUALIFIED == 1)); then
    ok "推荐缓冲区：${BEST_CANDIDATE} MiB；所有测试方向均达到各自最佳中位吞吐的 ${THRESHOLD_PERCENT}% 以上。"
else
    warn "没有候选在所有方向达到 ${THRESHOLD_PERCENT}% 阈值；已选择最低相对吞吐最高的候选。"
    warn "这通常表示链路波动较大、上限仍偏小，或服务端/中间链路存在瓶颈。"
    info "推荐缓冲区：${BEST_CANDIDATE} MiB；最差方向相对最佳值 ${BEST_MIN_RATIO}%。"
fi

FINAL_MIB=$BEST_CANDIDATE

if [[ "$APPLY_MODE" == "ask" ]]; then
    if [[ -t 0 ]]; then
        printf '\n候选值：%s MiB\n' "$CANDIDATE_LIST"
        read -r -p "应用推荐值 ${FINAL_MIB} MiB？[Y/n/输入其他候选值] " answer || answer="n"
        case "$answer" in
            ""|y|Y|yes|YES|是) APPLY_MODE="yes" ;;
            n|N|no|NO|否) APPLY_MODE="no" ;;
            *)
                if is_positive_integer "$answer" && printf '%s\n' "${CANDIDATES[@]}" | grep -qx "$answer"; then
                    FINAL_MIB=$answer
                    APPLY_MODE="yes"
                else
                    warn "输入不是有效候选值，不写入永久配置。"
                    APPLY_MODE="no"
                fi
                ;;
        esac
    else
        warn "非交互环境未指定 --apply；默认只输出推荐，不写永久配置。"
        APPLY_MODE="no"
    fi
fi

if [[ "$APPLY_MODE" == "no" ]]; then
    info "仅测试模式完成。推荐值：${FINAL_MIB} MiB。"
    exit 0
fi

FINAL_BYTES=$(mib_to_bytes "$FINAL_MIB")
FINAL_CORE_WMEM_MAX=$(max_number "$ORIG_CORE_WMEM_MAX" "$FINAL_BYTES")
FINAL_CORE_RMEM_MAX=$(max_number "$ORIG_CORE_RMEM_MAX" "$FINAL_BYTES")
CONFIG_DIR=${CONFIG_FILE%/*}
[[ "$CONFIG_DIR" == "$CONFIG_FILE" ]] && CONFIG_DIR="."
mkdir -p "$CONFIG_DIR"

TEMP_CONFIG=$(mktemp "$CONFIG_DIR/.auto-tune-tcp.XXXXXX")
BACKUP_FILE=""
if [[ -e "$CONFIG_FILE" ]]; then
    BACKUP_FILE="$WORK_DIR/$(basename "$CONFIG_FILE").backup"
    cp -a "$CONFIG_FILE" "$BACKUP_FILE"
fi

cat > "$TEMP_CONFIG" <<EOF
# Generated by $PROGRAM_NAME $VERSION on $(date --iso-8601=seconds 2>/dev/null || date)
# Target: $TARGET:$PORT
# Bottleneck bandwidth: ${BOTTLENECK_BW_Mbps} Mbps
# Measured RTT: ${RTT_MS} ms
# Theoretical BDP: ${BDP_MIB} MiB
# Selected max TCP buffer: ${FINAL_MIB} MiB (${FINAL_BYTES} bytes)
# Full test report: $WORK_DIR

net.core.wmem_max = $FINAL_CORE_WMEM_MAX
net.core.rmem_max = $FINAL_CORE_RMEM_MAX
net.ipv4.tcp_wmem = $ORIG_WMEM_MIN $ORIG_WMEM_DEFAULT $FINAL_BYTES
net.ipv4.tcp_rmem = $ORIG_RMEM_MIN $ORIG_RMEM_DEFAULT $FINAL_BYTES
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
EOF

chmod 0644 "$TEMP_CONFIG"
mv -f "$TEMP_CONFIG" "$CONFIG_FILE"

if ! sysctl -p "$CONFIG_FILE" | tee -a "$RUN_LOG"; then
    warn "应用配置失败，正在恢复。"
    if [[ -n "$BACKUP_FILE" ]]; then
        cp -a "$BACKUP_FILE" "$CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi
    restore_sysctl_state
    die "未能应用最终配置。"
fi

COMMITTED=1
ok "配置已写入并生效：$CONFIG_FILE"
ok "最终 TCP 缓冲区上限：${FINAL_MIB} MiB（${FINAL_BYTES} 字节）"
info "详细原始结果：$RESULTS_CSV"
info "聚合结果：$SUMMARY_TSV"
