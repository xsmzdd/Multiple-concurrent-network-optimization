#!/usr/bin/env bash

# SOCKS5 延迟与测速脚本
# 支持：Debian/Ubuntu、RHEL/CentOS/Rocky/Alma、Fedora、Alpine、Arch Linux
# Speedtest 节点策略：先检测代理出口国家/城市，再优先选择同国家同城市节点。

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/socks5-speedtest"
VENV_DIR="$CACHE_ROOT/venv"
WORK_DIR="$(mktemp -d -t socks5-speedtest.XXXXXX)"
PROXY_INFO="$WORK_DIR/proxy.info"
CURL_CFG="$WORK_DIR/curl.conf"
LATENCY_JSON="$WORK_DIR/latency.json"
SPEED_JSON="$WORK_DIR/speed.json"
HTTP_TSV="$WORK_DIR/http.tsv"
PING_OUT="$WORK_DIR/ping.txt"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[提示]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

run_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "缺少系统组件且当前不是 root，也没有 sudo。请先以 root 运行本脚本。"
    fi
}

python_venv_works() {
    command -v python3 >/dev/null 2>&1 || return 1
    local probe_dir="$WORK_DIR/venv-probe"

    rm -rf "$probe_dir"
    if python3 -m venv "$probe_dir" >/dev/null 2>&1 \
        && [[ -x "$probe_dir/bin/python" ]] \
        && "$probe_dir/bin/python" -m pip --version >/dev/null 2>&1; then
        rm -rf "$probe_dir"
        return 0
    fi

    rm -rf "$probe_dir"
    return 1
}

# apt-get update 可能被与本脚本无关的第三方源拖垮。
# 正常更新失败时，仅为安装本脚本依赖临时使用系统官方源；
# 不改写、不删除用户现有的 /etc/apt 源配置。
APT_ARGS=()

prepare_apt_for_dependencies() {
    APT_ARGS=()
    if run_root apt-get update; then
        return 0
    fi

    warn "系统 APT 源存在失效条目，正在尝试仅使用系统官方源安装脚本依赖。"

    local os_id=""
    local codename=""
    local source_file="$WORK_DIR/apt-dependencies.list"
    local lists_dir="$WORK_DIR/apt-lists"
    local arch=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        codename="${VERSION_CODENAME:-}"
    fi

    [[ -n "$os_id" ]] || fail "无法识别当前 Linux 发行版，请先修复系统软件源。"
    [[ -n "$codename" ]] || fail "无法识别系统版本代号，请先修复系统软件源。"

    case "$os_id" in
        debian)
            case "$codename" in
                bullseye|bookworm|trixie|forky)
                    cat > "$source_file" <<EOF
# 仅供本脚本安装依赖使用，不会覆盖系统源。
deb https://deb.debian.org/debian $codename main contrib non-free non-free-firmware
deb https://deb.debian.org/debian $codename-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security $codename-security main contrib non-free non-free-firmware
EOF
                    ;;
                buster)
                    cat > "$source_file" <<'EOF'
# Debian 10 已归档；仅供本脚本安装依赖使用。
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian buster-updates main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF
                    APT_ARGS+=( -o Acquire::Check-Valid-Until=false )
                    ;;
                *)
                    fail "APT 更新失败，脚本暂不支持为 Debian ${codename} 自动生成临时官方源。"
                    ;;
            esac
            ;;
        ubuntu)
            arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
            case "$codename" in
                focal|jammy|noble|resolute)
                    if [[ "$arch" == "amd64" || "$arch" == "i386" ]]; then
                        cat > "$source_file" <<EOF
# 仅供本脚本安装依赖使用，不会覆盖系统源。
deb http://archive.ubuntu.com/ubuntu $codename main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $codename-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $codename-security main restricted universe multiverse
EOF
                    else
                        cat > "$source_file" <<EOF
# Ubuntu 非 x86 架构官方源；仅供本脚本安装依赖使用。
deb http://ports.ubuntu.com/ubuntu-ports $codename main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-security main restricted universe multiverse
EOF
                    fi
                    ;;
                *)
                    fail "APT 更新失败，脚本暂不支持为 Ubuntu ${codename} 自动生成临时官方源。"
                    ;;
            esac
            ;;
        *)
            fail "APT 更新失败，且当前系统 ${os_id} 暂不支持自动官方源回退。请先修复系统软件源。"
            ;;
    esac

    chmod 0644 "$source_file"
    mkdir -p "$lists_dir/partial"

    APT_ARGS+=(
        -o "Dir::Etc::sourcelist=$source_file"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State::lists=$lists_dir"
        -o "APT::Get::List-Cleanup=0"
    )

    run_root apt-get "${APT_ARGS[@]}" update \
        || fail "使用系统官方临时源更新仍然失败，请检查网络、DNS 和系统时间。"

    ok "已绕过失效的第三方 APT 源；仅使用系统官方源安装本脚本依赖。"
}

apt_install_packages() {
    run_root env DEBIAN_FRONTEND=noninteractive \
        apt-get "${APT_ARGS[@]}" install -y "$@"
}

install_system_dependencies() {
    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v ping >/dev/null 2>&1 || missing+=(ping)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v timeout >/dev/null 2>&1 || missing+=(timeout)

    if ((${#missing[@]} == 0)) && python_venv_works; then
        ok "系统基础组件已就绪。"
        return
    fi

    info "正在安装脚本运行所需组件……"

    if command -v apt-get >/dev/null 2>&1; then
        prepare_apt_for_dependencies
        apt_install_packages \
            curl ca-certificates iputils-ping python3 python3-pip coreutils

        if ! python_venv_works; then
            if ! apt_install_packages python3-venv; then
                local pyver
                pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
                apt_install_packages "python${pyver}-venv"
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y curl ca-certificates iputils python3 python3-pip coreutils
    elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y curl ca-certificates iputils python3 python3-pip coreutils
    elif command -v apk >/dev/null 2>&1; then
        run_root apk add --no-cache curl ca-certificates iputils python3 py3-pip coreutils
    elif command -v pacman >/dev/null 2>&1; then
        run_root pacman -Sy --noconfirm --needed curl ca-certificates iputils python python-pip coreutils
    else
        fail "无法识别系统包管理器。请手动安装：curl、ping、python3、python3-venv/pip、timeout。"
    fi

    command -v curl >/dev/null 2>&1 || fail "curl 安装失败。"
    command -v ping >/dev/null 2>&1 || fail "ping 安装失败。"
    command -v python3 >/dev/null 2>&1 || fail "python3 安装失败。"
    command -v timeout >/dev/null 2>&1 || fail "timeout 安装失败。"
    python_venv_works || fail "Python venv/ensurepip 仍不可用。Debian/Ubuntu 请安装 python3-venv 或对应版本的 pythonX.Y-venv。"

    ok "系统组件安装完成。"
}

venv_is_usable() {
    [[ -x "$VENV_DIR/bin/python" ]] \
        && "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1
}

prepare_python_environment() {
    mkdir -p "$CACHE_ROOT"

    if ! venv_is_usable; then
        info "正在创建独立 Python 环境……"
        rm -rf "$VENV_DIR"

        if ! python3 -m venv "$VENV_DIR" \
            || ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
            rm -rf "$VENV_DIR"
            fail "无法创建可用的 Python venv。请确认已安装 python3-venv 或对应版本的 pythonX.Y-venv。"
        fi
    fi

    local py="$VENV_DIR/bin/python"
    if ! "$py" -c 'import socks, speedtest' >/dev/null 2>&1; then
        info "正在安装 PySocks 与 speedtest-cli……"
        "$py" -m pip install --disable-pip-version-check --quiet --upgrade pip setuptools wheel
        "$py" -m pip install --disable-pip-version-check --quiet --upgrade PySocks speedtest-cli
    fi

    "$py" -c 'import socks, speedtest' >/dev/null 2>&1 \
        || fail "Python 测速组件安装失败。"

    ok "Python 测速组件已就绪。"
}

validate_proxy_input() {
    local raw="$1"

    # read 的最后一个变量会接收剩余字段，因此密码中可以包含冒号；用户名不能包含冒号。
    IFS=':' read -r PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS <<< "$raw"

    [[ -n "${PROXY_HOST:-}" ]] || fail "代理 IP/主机名不能为空。"
    [[ "${PROXY_PORT:-}" =~ ^[0-9]+$ ]] || fail "代理端口必须是数字。"
    (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || fail "代理端口范围必须是 1-65535。"
    [[ -n "${PROXY_USER:-}" ]] || fail "用户名不能为空。"
    [[ -n "${PROXY_PASS:-}" ]] || fail "密码不能为空。"
    ((${#PROXY_USER} <= 255)) || fail "SOCKS5 用户名不能超过 255 字节。"
    ((${#PROXY_PASS} <= 255)) || fail "SOCKS5 密码不能超过 255 字节。"

    [[ "$PROXY_HOST" != *:* ]] || fail "当前输入格式不支持 IPv6 地址，请使用 IPv4 或主机名。"
}

curl_cfg_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

write_private_configs() {
    umask 077
    printf '%s\n%s\n%s\n%s\n' \
        "$PROXY_HOST" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS" > "$PROXY_INFO"

    local esc_host esc_user esc_pass
    esc_host="$(curl_cfg_escape "$PROXY_HOST")"
    esc_user="$(curl_cfg_escape "$PROXY_USER")"
    esc_pass="$(curl_cfg_escape "$PROXY_PASS")"

    cat > "$CURL_CFG" <<EOF
proxy = "socks5h://${esc_host}:${PROXY_PORT}"
proxy-user = "${esc_user}:${esc_pass}"
EOF

    chmod 600 "$PROXY_INFO" "$CURL_CFG"
}

run_ping_test() {
    PING_RESULT="测试延迟失败"
    : > "$PING_OUT"

    if ping -n -c 4 -W 2 "$PROXY_HOST" >"$PING_OUT" 2>&1; then
        local avg
        avg="$(awk -F'/' '/min\/avg\/max|round-trip/ {print $5; exit}' "$PING_OUT" 2>/dev/null || true)"

        if [[ -z "$avg" ]]; then
            avg="$(awk '
                /time[=<]/ {
                    line=$0
                    sub(/^.*time[=<]/, "", line)
                    sub(/[[:space:]]*ms.*$/, "", line)
                    if (line ~ /^[0-9.]+$/) {sum+=line; n++}
                }
                END {if (n>0) printf "%.2f", sum/n}
            ' "$PING_OUT")"
        fi

        [[ -n "$avg" ]] && PING_RESULT="${avg} ms"
    fi
}

run_socket_latency_tests() {
    local py="$VENV_DIR/bin/python"
    local helper="$WORK_DIR/latency_test.py"

    cat > "$helper" <<'PY'
import json
import socket
import statistics
import sys
import time


def read_proxy(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    if len(lines) < 4:
        raise ValueError("代理配置不完整")
    return lines[0], int(lines[1]), lines[2], lines[3]


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("SOCKS5 服务器提前关闭连接")
        data.extend(chunk)
    return bytes(data)


def tcp_once(host, port, timeout=5):
    start = time.perf_counter()
    with socket.create_connection((host, port), timeout=timeout):
        pass
    return (time.perf_counter() - start) * 1000


def socks_handshake_once(host, port, username, password, timeout=7):
    start = time.perf_counter()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(bytes([0x05, 0x02, 0x00, 0x02]))
        version, method = recv_exact(sock, 2)

        if version != 0x05:
            raise RuntimeError(f"无效 SOCKS 版本: {version}")
        if method == 0xFF:
            raise PermissionError("代理拒绝了所有认证方式")

        if method == 0x02:
            user_b = username.encode("utf-8")
            pass_b = password.encode("utf-8")
            if len(user_b) > 255 or len(pass_b) > 255:
                raise ValueError("用户名或密码超过 SOCKS5 限制")

            sock.sendall(
                bytes([0x01, len(user_b)])
                + user_b
                + bytes([len(pass_b)])
                + pass_b
            )
            auth_ver, status = recv_exact(sock, 2)
            if auth_ver != 0x01 or status != 0x00:
                raise PermissionError("SOCKS5 用户名或密码认证失败")
        elif method != 0x00:
            raise RuntimeError(f"代理选择了不支持的认证方式: {method}")

    return (time.perf_counter() - start) * 1000


def measure(func, count=5):
    values = []
    errors = []

    for _ in range(count):
        try:
            values.append(func())
        except Exception as exc:
            errors.append(f"{type(exc).__name__}: {exc}")
        time.sleep(0.15)

    if not values:
        return {
            "ok": False,
            "successes": 0,
            "attempts": count,
            "error": errors[-1] if errors else "未知错误",
        }

    return {
        "ok": True,
        "successes": len(values),
        "attempts": count,
        "avg_ms": round(statistics.mean(values), 2),
        "median_ms": round(statistics.median(values), 2),
        "min_ms": round(min(values), 2),
        "max_ms": round(max(values), 2),
        "last_error": errors[-1] if errors else "",
    }


def main():
    host, port, username, password = read_proxy(sys.argv[1])
    result = {
        "tcp": measure(lambda: tcp_once(host, port)),
        "socks_handshake": measure(
            lambda: socks_handshake_once(host, port, username, password)
        ),
    }
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
PY

    if ! "$py" "$helper" "$PROXY_INFO" > "$LATENCY_JSON"; then
        printf '%s\n' '{"tcp":{"ok":false,"error":"延迟测试程序运行失败"},"socks_handshake":{"ok":false,"error":"延迟测试程序运行失败"}}' > "$LATENCY_JSON"
    fi
}

run_http_latency_tests() {
    : > "$HTTP_TSV"

    local names=("Cloudflare" "Cloudflare-Speed" "Google-204" "IPify")
    local urls=(
        "https://www.cloudflare.com/cdn-cgi/trace"
        "https://speed.cloudflare.com/"
        "https://www.google.com/generate_204"
        "https://api.ipify.org"
    )

    local i run output rc connect first total code
    local sum_connect sum_first sum_total count

    for i in "${!urls[@]}"; do
        sum_connect="0"
        sum_first="0"
        sum_total="0"
        count=0

        for run in 1 2; do
            set +e
            output="$(curl --config "$CURL_CFG" \
                --silent --show-error --output /dev/null \
                --connect-timeout 10 --max-time 25 \
                --write-out $'%{time_connect}\t%{time_starttransfer}\t%{time_total}\t%{http_code}' \
                "${urls[$i]}" 2>/dev/null)"
            rc=$?
            set -e

            if [[ $rc -eq 0 ]]; then
                IFS=$'\t' read -r connect first total code <<< "$output"
                if [[ "$connect" =~ ^[0-9.]+$ \
                    && "$first" =~ ^[0-9.]+$ \
                    && "$total" =~ ^[0-9.]+$ \
                    && "$code" =~ ^[0-9]{3}$ \
                    && "$code" != "000" ]]; then
                    sum_connect="$(awk -v a="$sum_connect" -v b="$connect" 'BEGIN{printf "%.6f", a+b}')"
                    sum_first="$(awk -v a="$sum_first" -v b="$first" 'BEGIN{printf "%.6f", a+b}')"
                    sum_total="$(awk -v a="$sum_total" -v b="$total" 'BEGIN{printf "%.6f", a+b}')"
                    ((count+=1))
                fi
            fi
        done

        if ((count > 0)); then
            local avg_connect avg_first avg_total
            avg_connect="$(awk -v s="$sum_connect" -v n="$count" 'BEGIN{printf "%.2f", s*1000/n}')"
            avg_first="$(awk -v s="$sum_first" -v n="$count" 'BEGIN{printf "%.2f", s*1000/n}')"
            avg_total="$(awk -v s="$sum_total" -v n="$count" 'BEGIN{printf "%.2f", s*1000/n}')"

            printf '%s\t成功\t%s\t%s\t%s\t%s\n' \
                "${names[$i]}" "$avg_connect" "$avg_first" "$avg_total" "$count" >> "$HTTP_TSV"
        else
            printf '%s\t失败\t-\t-\t-\t0\n' "${names[$i]}" >> "$HTTP_TSV"
        fi
    done

    set +e
    EXIT_IP="$(curl --config "$CURL_CFG" --silent --show-error \
        --connect-timeout 10 --max-time 20 https://api.ipify.org 2>/dev/null)"
    rc=$?
    set -e

    if [[ $rc -ne 0 || -z "$EXIT_IP" ]]; then
        EXIT_IP="获取失败"
    fi
}

run_speedtest() {
    local py="$VENV_DIR/bin/python"
    local helper="$WORK_DIR/run_speedtest.py"

    cat > "$helper" <<'PY'
import json
import math
import socket
import sys
import time
import unicodedata
from urllib.request import Request, urlopen

import socks


def read_proxy(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    if len(lines) < 4:
        raise ValueError("代理配置不完整")
    return lines[0], int(lines[1]), lines[2], lines[3]


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def fetch_json(url, timeout=12):
    request = Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 socks5-speedtest/2.0",
            "Accept": "application/json",
        },
    )
    with urlopen(request, timeout=timeout) as response:
        raw = response.read().decode("utf-8", errors="replace")
    return json.loads(raw)


def empty_location(errors=None):
    return {
        "provider": "",
        "ip": "",
        "country_code": "",
        "country_name": "",
        "region": "",
        "city": "",
        "latitude": None,
        "longitude": None,
        "errors": errors or [],
    }


def detect_exit_location():
    """定位请求在 socket 替换后执行，因此也会经过 SOCKS5。"""
    errors = []
    providers = (
        ("ipwho.is", "https://ipwho.is/"),
        ("ipapi.co", "https://ipapi.co/json/"),
    )

    for provider, url in providers:
        try:
            data = fetch_json(url)

            if provider == "ipwho.is":
                if data.get("success") is False:
                    raise RuntimeError(data.get("message") or "定位接口返回失败")
                country_code = data.get("country_code") or ""
                country_name = data.get("country") or ""
            else:
                if data.get("error"):
                    raise RuntimeError(
                        data.get("reason")
                        or data.get("message")
                        or "定位接口返回失败"
                    )
                country_code = data.get("country_code") or data.get("country") or ""
                country_name = data.get("country_name") or ""

            country_code = str(country_code).strip().upper()
            if len(country_code) != 2:
                raise RuntimeError("定位结果没有有效的两位国家代码")

            return {
                "provider": provider,
                "ip": str(data.get("ip") or "").strip(),
                "country_code": country_code,
                "country_name": str(country_name).strip(),
                "region": str(data.get("region") or data.get("region_name") or "").strip(),
                "city": str(data.get("city") or "").strip(),
                "latitude": to_float(data.get("latitude")),
                "longitude": to_float(data.get("longitude")),
                "errors": errors,
            }
        except Exception as exc:
            errors.append(f"{provider}: {type(exc).__name__}: {exc}")

    return empty_location(errors)


def normalize_place(value):
    value = unicodedata.normalize("NFKD", str(value or ""))
    value = "".join(char for char in value if not unicodedata.combining(char))
    value = value.casefold()
    return " ".join(
        "".join(char if char.isalnum() else " " for char in value).split()
    )


def city_matches(server_name, detected_city):
    if not server_name or not detected_city:
        return False

    full_name = normalize_place(server_name)
    main_name = normalize_place(str(server_name).split(",", 1)[0])
    city_name = normalize_place(detected_city)

    if not city_name or not main_name:
        return False

    return (
        full_name == city_name
        or main_name == city_name
        or full_name.startswith(city_name + " ")
        or city_name.startswith(main_name + " ")
    )


def haversine_distance(lat1, lon1, lat2, lon2):
    radius = 6371.0
    lat1 = math.radians(float(lat1))
    lon1 = math.radians(float(lon1))
    lat2 = math.radians(float(lat2))
    lon2 = math.radians(float(lon2))
    delta_lat = lat2 - lat1
    delta_lon = lon2 - lon1

    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    value = min(1.0, max(0.0, value))
    return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value))


def server_distance(server, location):
    location_lat = location.get("latitude")
    location_lon = location.get("longitude")
    server_lat = to_float(server.get("lat"))
    server_lon = to_float(server.get("lon"))

    if (
        location_lat is not None
        and location_lon is not None
        and server_lat is not None
        and server_lon is not None
    ):
        return haversine_distance(
            location_lat,
            location_lon,
            server_lat,
            server_lon,
        )

    distance = to_float(server.get("d"))
    return distance if distance is not None else float("inf")


def flatten_servers(server_groups):
    servers = []
    for group in server_groups.values():
        servers.extend(group)
    return servers


def choose_server(speedtest_client, location):
    server_groups = speedtest_client.get_servers()
    all_servers = flatten_servers(server_groups)
    if not all_servers:
        raise RuntimeError("Speedtest 没有返回可用测速节点")

    country_code = str(location.get("country_code") or "").upper()
    city = str(location.get("city") or "")

    same_country = [
        server
        for server in all_servers
        if str(server.get("cc") or "").upper() == country_code
    ]
    same_city = [
        server
        for server in same_country
        if city_matches(server.get("name"), city)
    ]

    if same_city:
        same_city.sort(key=lambda server: server_distance(server, location))
        candidates = same_city[:10]
        best = speedtest_client.get_best_server(candidates)
        return best, {
            "mode": "same_city",
            "description": "同国家、同城市",
            "candidate_count": len(same_city),
            "latency_tested_count": len(candidates),
        }

    if same_country:
        same_country.sort(key=lambda server: server_distance(server, location))
        candidates = same_country[:10]
        best = speedtest_client.get_best_server(candidates)
        return best, {
            "mode": "same_country_nearest",
            "description": "未找到同城节点，使用同国家最近候选节点",
            "candidate_count": len(same_country),
            "latency_tested_count": len(candidates),
        }

    best = speedtest_client.get_best_server()
    return best, {
        "mode": "automatic",
        "description": "定位失败或无同国家节点，使用 Speedtest 自动节点",
        "candidate_count": len(all_servers),
        "latency_tested_count": 5,
    }


def main():
    host, port, username, password = read_proxy(sys.argv[1])

    # 在导入 speedtest 之前替换 socket，确保定位、配置、节点列表及测速全部走 SOCKS5。
    socks.set_default_proxy(
        socks.SOCKS5,
        host,
        port,
        rdns=True,
        username=username,
        password=password,
    )

    original_timeout = socket._GLOBAL_DEFAULT_TIMEOUT

    def proxy_create_connection(
        address,
        timeout=original_timeout,
        source_address=None,
    ):
        effective_timeout = None if timeout is original_timeout else timeout
        return socks.create_connection(
            address,
            timeout=effective_timeout,
            source_address=source_address,
            proxy_type=socks.SOCKS5,
            proxy_addr=host,
            proxy_port=port,
            proxy_rdns=True,
            proxy_username=username,
            proxy_password=password,
        )

    socket.socket = socks.socksocket
    socket.create_connection = proxy_create_connection

    import speedtest

    started = time.perf_counter()
    location = detect_exit_location()
    speedtest_client = speedtest.Speedtest(secure=True, timeout=20)

    # 外部定位接口均失败时，用 Speedtest 配置中的国家和坐标回退。
    # Speedtest 配置通常没有城市字段，因此此时只能选择同国家最近节点。
    if not location.get("country_code"):
        client = speedtest_client.config.get("client", {})
        location["provider"] = "Speedtest.net"
        location["ip"] = str(client.get("ip") or "")
        location["country_code"] = str(client.get("country") or "").upper()
        location["latitude"] = to_float(client.get("lat"))
        location["longitude"] = to_float(client.get("lon"))

    best, selection = choose_server(speedtest_client, location)
    download_bps = speedtest_client.download()
    upload_bps = speedtest_client.upload(pre_allocate=False)

    result = {
        "ok": True,
        "engine": "speedtest-cli / Speedtest.net",
        "exit_ip": location.get("ip", ""),
        "exit_country_code": location.get("country_code", ""),
        "exit_country": location.get("country_name", ""),
        "exit_region": location.get("region", ""),
        "exit_city": location.get("city", ""),
        "geo_provider": location.get("provider", ""),
        "geo_errors": location.get("errors", []),
        "selection_mode": selection["mode"],
        "selection_description": selection["description"],
        "candidate_count": selection["candidate_count"],
        "latency_tested_count": selection["latency_tested_count"],
        "server_id": str(best.get("id", "")),
        "server_name": best.get("name", ""),
        "server_country": best.get("country", ""),
        "server_country_code": best.get("cc", ""),
        "server_sponsor": best.get("sponsor", ""),
        "server_host": best.get("host", ""),
        "distance_km": round(float(best.get("d", 0.0)), 2),
        "ping_ms": round(float(speedtest_client.results.ping), 2),
        "download_mbps": round(download_bps / 1_000_000, 2),
        "upload_mbps": round(upload_bps / 1_000_000, 2),
        "elapsed_seconds": round(time.perf_counter() - started, 2),
    }
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                },
                ensure_ascii=False,
            )
        )
        raise SystemExit(1)
PY

    info "正在通过 SOCKS5 检测出口位置并运行 Speedtest 下载/上传测速……"

    local rc
    set +e
    if command -v timeout >/dev/null 2>&1; then
        timeout 300 "$py" "$helper" "$PROXY_INFO" > "$SPEED_JSON" 2>/dev/null
        rc=$?
    else
        "$py" "$helper" "$PROXY_INFO" > "$SPEED_JSON" 2>/dev/null
        rc=$?
    fi
    set -e

    if [[ $rc -eq 124 ]]; then
        printf '%s\n' '{"ok":false,"error":"Speedtest 超过 300 秒，已终止"}' > "$SPEED_JSON"
    elif [[ ! -s "$SPEED_JSON" ]]; then
        printf '%s\n' '{"ok":false,"error":"Speedtest 未返回结果"}' > "$SPEED_JSON"
    fi
}

print_json_section() {
    local py="$VENV_DIR/bin/python"

    "$py" - "$LATENCY_JSON" "$SPEED_JSON" <<'PY'
import json
import sys

latency_path, speed_path = sys.argv[1], sys.argv[2]


def load(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return fallback


latency = load(latency_path, {})
speed = load(speed_path, {"ok": False, "error": "无法解析测速结果"})
tcp = latency.get("tcp", {})
handshake = latency.get("socks_handshake", {})

if tcp.get("ok"):
    print(
        f"TCP端口连接: 平均 {tcp['avg_ms']:.2f} ms | "
        f"中位 {tcp['median_ms']:.2f} ms | "
        f"最低 {tcp['min_ms']:.2f} ms | "
        f"成功 {tcp['successes']}/{tcp['attempts']}"
    )
else:
    print(f"TCP端口连接: 测试延迟失败（{tcp.get('error', '未知错误')}）")

if handshake.get("ok"):
    print(
        f"SOCKS5握手/认证: 平均 {handshake['avg_ms']:.2f} ms | "
        f"中位 {handshake['median_ms']:.2f} ms | "
        f"最低 {handshake['min_ms']:.2f} ms | "
        f"成功 {handshake['successes']}/{handshake['attempts']}"
    )
else:
    print(
        "SOCKS5握手/认证: 测试延迟失败"
        f"（{handshake.get('error', '未知错误')}）"
    )

print("\n--- Speedtest 测速 ---")
if speed.get("ok"):
    location_parts = [
        speed.get("exit_country") or speed.get("exit_country_code", ""),
        speed.get("exit_region", ""),
        speed.get("exit_city", ""),
    ]
    location_text = " / ".join(x for x in location_parts if x) or "定位失败"

    server_parts = [
        speed.get("server_sponsor", ""),
        speed.get("server_name", ""),
        speed.get("server_country", ""),
    ]
    server = " / ".join(x for x in server_parts if x) or "未知服务器"

    print(f"测速引擎: {speed.get('engine', 'Speedtest')}")
    print(
        f"出口位置: {location_text}"
        f"（IP: {speed.get('exit_ip') or '-'}，定位来源: {speed.get('geo_provider') or '-'}）"
    )
    print(
        f"节点选择: {speed.get('selection_description', '-')}"
        f"（匹配 {speed.get('candidate_count', 0)} 个，"
        f"延迟比较 {speed.get('latency_tested_count', 0)} 个）"
    )
    print(f"测速服务器: {server}（ID: {speed.get('server_id', '-')}）")
    print(f"服务器距离: {speed.get('distance_km', 0):.2f} km")
    print(f"Speedtest Ping: {speed.get('ping_ms', 0):.2f} ms")
    print(f"下载速度: {speed.get('download_mbps', 0):.2f} Mbps")
    print(f"上传速度: {speed.get('upload_mbps', 0):.2f} Mbps")
    print(f"测速耗时: {speed.get('elapsed_seconds', 0):.2f} 秒")
else:
    print(f"测速失败: {speed.get('error', '未知错误')}")
PY
}

print_report() {
    printf '\n\033[1;36m================ SOCKS5 测试结果 ================\033[0m\n'
    printf '代理地址: %s:%s\n' "$PROXY_HOST" "$PROXY_PORT"
    printf '代理出口IP: %s\n' "$EXIT_IP"

    printf '\n--- 测试机到代理的延迟 ---\n'
    if [[ "$PING_RESULT" == "测试延迟失败" ]]; then
        printf 'Ping: 测试延迟失败\n'
    else
        printf 'Ping: %s\n' "$PING_RESULT"
    fi

    print_json_section

    printf '\n--- 通过代理访问网站的延迟 ---\n'
    printf '%-14s %-8s %-14s %-14s %-14s\n' "目标" "状态" "连接代理" "首字节" "总耗时"

    while IFS=$'\t' read -r name status connect first total samples; do
        if [[ "$status" == "成功" ]]; then
            printf '%-14s %-8s %-14s %-14s %-14s\n' \
                "$name" "$status" "${connect} ms" "${first} ms" "${total} ms"
        else
            printf '%-14s %-8s %-14s %-14s %-14s\n' \
                "$name" "$status" "测试失败" "测试失败" "测试失败"
        fi
    done < "$HTTP_TSV"

    printf '\033[1;36m==================================================\033[0m\n'
    warn "Speedtest 优先选择出口 IP 同国家同城市节点；无同城节点时选择同国家最近候选节点。"
    warn "IP 城市定位属于近似数据，可能显示为运营商注册城市。"
}

main() {
    [[ "$(uname -s)" == "Linux" ]] || fail "此版本脚本仅支持 Linux。"

    printf '\nSOCKS5 延迟与 Speedtest 测速脚本\n'
    printf '%s\n' '----------------------------------'

    install_system_dependencies
    prepare_python_environment

    local proxy_input
    printf '\n输入格式：IP:端口:用户名:密码\n'
    printf '说明：输入内容会隐藏；密码可以包含冒号，用户名不能包含冒号。\n'
    read -r -s -p "请输入 SOCKS5 代理: " proxy_input
    printf '\n'

    validate_proxy_input "$proxy_input"
    unset proxy_input
    write_private_configs

    info "正在测试 ICMP Ping、TCP 连接和 SOCKS5 握手/认证延迟……"
    run_ping_test
    run_socket_latency_tests

    info "正在通过 SOCKS5 测试多个 HTTPS 目标的延迟……"
    run_http_latency_tests

    run_speedtest
    print_report
}

main "$@"
