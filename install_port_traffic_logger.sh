#!/bin/bash
set -e

SERVICE_NAME="port-traffic-logger"
LOGGER_PATH="/root/port_traffic_logger.py"
LOG_FILE="/root/port_traffic.log"
OUT_FILE="/root/port_traffic_logger.out"
TARGET_PROCS="realm,gost,ehco"

echo "========== Port Traffic Logger Installer =========="

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

echo "[1/7] 安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y tcpdump python3 iproute2 procps systemd

echo "[2/7] 自动检测网卡..."
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')

if [ -z "$IFACE" ]; then
    IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
fi

if [ -z "$IFACE" ]; then
    echo "无法自动检测网卡，请手动查看：ip a"
    exit 1
fi

echo "检测到网卡：$IFACE"

echo "[3/7] 停止旧服务..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
pkill -f port_traffic_logger.py 2>/dev/null || true

echo "[4/7] 创建新版记录脚本..."
cat > "$LOGGER_PATH" <<'PYEOF'
#!/usr/bin/env python3
import subprocess
import re
import time
import signal
import sys
import csv
import os
from collections import defaultdict

IFACE = sys.argv[1] if len(sys.argv) > 1 else "eth0"

# 只记录这些进程监听端口的流量
TARGET_PROCS = ["realm", "gost", "ehco"]

LOG_FILE = "/root/port_traffic.log"

# 内部仍用 bytes 累加，写入文件时转换成 MB
stats = defaultdict(lambda: {"in": 0, "out": 0})
monitored_ports = {}

length_re = re.compile(r"length (\d+)")
pkt_re = re.compile(r" IP (\S+)\.(\d+) > (\S+)\.(\d+):")

def b_to_mb(n):
    return n / 1024 / 1024

def extract_port(local_addr):
    local_addr = local_addr.strip()

    if local_addr.endswith(":*"):
        return None

    if "]:" in local_addr:
        return local_addr.rsplit("]:", 1)[1]

    if ":" in local_addr:
        return local_addr.rsplit(":", 1)[1]

    return None

def refresh_monitored_ports():
    """
    获取 realm/gost/ehco 当前正在监听的 TCP/UDP 端口。
    """
    global monitored_ports
    new_ports = {}

    try:
        out = subprocess.check_output(
            ["ss", "-H", "-lntup"],
            stderr=subprocess.DEVNULL,
            text=True
        )
    except Exception:
        return

    for line in out.splitlines():
        proc_name = None

        for name in TARGET_PROCS:
            if f'("{name}",' in line or f'("{name}"' in line:
                proc_name = name
                break

        if not proc_name:
            continue

        parts = line.split()
        if len(parts) < 5:
            continue

        proto = parts[0].lower()
        local_addr = parts[4]
        port = extract_port(local_addr)

        if not port or not port.isdigit():
            continue

        new_ports[(proto, port)] = proc_name

    monitored_ports = new_ports

def load_existing_stats():
    """
    兼容旧日志：
    旧格式: proto,process,port,in_bytes,out_bytes,total_bytes
    新格式: proto,process,port,in_mb,out_mb,total_mb
    """
    if not os.path.exists(LOG_FILE):
        return

    try:
        with open(LOG_FILE, newline="") as f:
            reader = csv.DictReader(f)
            fields = reader.fieldnames or []

            old_bytes = "in_bytes" in fields
            old_mb = "in_mb" in fields

            for row in reader:
                proto = row.get("proto")
                proc = row.get("process")
                port = row.get("port")

                if not proto or not proc or not port:
                    continue

                key = (proto, proc, port)

                if old_bytes:
                    stats[key]["in"] = int(float(row.get("in_bytes", 0)))
                    stats[key]["out"] = int(float(row.get("out_bytes", 0)))
                elif old_mb:
                    stats[key]["in"] = int(float(row.get("in_mb", 0)) * 1024 * 1024)
                    stats[key]["out"] = int(float(row.get("out_mb", 0)) * 1024 * 1024)

    except Exception:
        pass

def save():
    with open(LOG_FILE, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["proto", "process", "port", "in_mb", "out_mb", "total_mb"])

        for key in sorted(stats.keys(), key=lambda x: (x[1], x[0], int(x[2]))):
            proto, proc, port = key
            inbound = stats[key]["in"]
            outbound = stats[key]["out"]
            total = inbound + outbound

            writer.writerow([
                proto,
                proc,
                port,
                f"{b_to_mb(inbound):.2f}",
                f"{b_to_mb(outbound):.2f}",
                f"{b_to_mb(total):.2f}"
            ])

def handle_exit(signum, frame):
    save()
    sys.exit(0)

signal.signal(signal.SIGINT, handle_exit)
signal.signal(signal.SIGTERM, handle_exit)

load_existing_stats()
refresh_monitored_ports()

cmd = [
    "tcpdump",
    "-i", IFACE,
    "-n",
    "-l",
    "ip and (tcp or udp)"
]

print(f"Recording traffic on interface: {IFACE}")
print(f"Target processes: {', '.join(TARGET_PROCS)}")
print(f"Log file: {LOG_FILE}")
print("Unit: MB")
print("Only listening ports owned by target processes will be counted.")

p = subprocess.Popen(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True
)

last_save = time.time()
last_refresh = 0

for line in p.stdout:
    now = time.time()

    if now - last_refresh >= 5:
        refresh_monitored_ports()
        last_refresh = now

    m = pkt_re.search(line)
    l = length_re.search(line)

    if not m or not l:
        continue

    src_ip, src_port, dst_ip, dst_port = m.group(1), m.group(2), m.group(3), m.group(4)
    length = int(l.group(1))

    proto = "udp" if " UDP," in line else "tcp"

    # 入站：目标端口是目标进程监听端口
    in_key = (proto, dst_port)
    if in_key in monitored_ports:
        proc = monitored_ports[in_key]
        stats[(proto, proc, dst_port)]["in"] += length

    # 出站：源端口是目标进程监听端口
    out_key = (proto, src_port)
    if out_key in monitored_ports:
        proc = monitored_ports[out_key]
        stats[(proto, proc, src_port)]["out"] += length

    if now - last_save >= 10:
        save()
        last_save = now
PYEOF

chmod +x "$LOGGER_PATH"

echo "[5/7] 创建 systemd 服务..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF2
[Unit]
Description=Port Traffic Logger for realm gost ehco
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $LOGGER_PATH $IFACE
Restart=always
RestartSec=5
StandardOutput=append:$OUT_FILE
StandardError=append:$OUT_FILE

[Install]
WantedBy=multi-user.target
EOF2

echo "[6/7] 启动服务..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

sleep 2

echo "[7/7] 检查状态..."
systemctl --no-pager status "$SERVICE_NAME" || true

echo
echo "========== 安装完成 =========="
echo "网卡：$IFACE"
echo "记录进程：$TARGET_PROCS"
echo "统计文件：$LOG_FILE"
echo "运行日志：$OUT_FILE"
echo
echo "查看统计："
echo "  column -t -s, $LOG_FILE"
echo
echo "实时查看："
echo "  watch -n 2 'column -t -s, $LOG_FILE'"
echo
echo "查看监听端口："
echo "  ss -lntup | grep -E 'realm|gost|ehco'"
echo
echo "查看服务状态："
echo "  systemctl status $SERVICE_NAME"
echo
echo "查看运行日志："
echo "  tail -f $OUT_FILE"
