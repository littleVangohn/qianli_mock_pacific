#!/bin/bash
# ============================================================================
# cquqianli_mock 一键启动 —— WSL 里跑这一条就够
#
#   bash /mnt/d/Pacific_doorlock/cquqianli_mock/run.sh
#
# 为什么需要"一条命令管到底"：
#   自定义客户端拿不到数据，90% 是下面四件事之一没做对。它们互相依赖、顺序不能换，
#   所以全部收进这里，避免每次开机靠记忆敲一串。
#
#   1. 稳定本机   —— 放大内核 UDP 接收缓冲、杀掉抢 ClientId 的残留客户端
#   2. 稳定寻址   —— WSL 的 IP 每次重启会变，把 config.json 重新指向当前 Windows 主机
#   3. 拉起官方选手端 —— 它身兼两职：MQTT broker（3333）+ 赛事数据桥接。
#                        不开它，自定义客户端连 3333 都连不上，更不会有数据。
#                        （数据源头再往上一级是裁判系统栈，本脚本不负责，见 README）
#   4. 等就绪再连  —— 轮询 3333 直到 broker 真的在监听，并确认 ClientId 空闲
#
# 首次部署想彻底摆脱"每次弹 UAC"，先跑一次（只需一次管理员授权）：
#
#   bash .../run.sh --fix-acl
#
# 它给官方选手端目录补上当前 Windows 用户的写权限。做完之后 ty 就能直接启动，
# 不再需要管理员。
#
# 可选环境变量：
#   RM26_BUILD_DIR       自定义客户端的构建目录（默认 ~/rm26-build）
#   RM_CLIENT_ROBOT_ID   覆盖机器人编号（默认读 config.json）
# ============================================================================
set -uo pipefail

# --- 路径：全部从脚本自身推导，因此仓库改名/搬家都不影响 -------------------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(dirname "$SELF")"
UPSTREAM="$REPO/upstream"
CONFIG="$UPSTREAM/config.json"
BUILD="${RM26_BUILD_DIR:-$HOME/rm26-build}"
CLIENT_EXE="$BUILD/RoboMasterClient2025"

# --- Windows 侧（官方选手端） ----------------------------------------------
WIN_DIR='/mnt/d/Pacific_doorlock/从零开始认识裁判系统/RoboMasterClient 12.0.0.213_Student/RoboMasterClient 12.0.0.213_Student/RoboMasterClient'
WIN_DIR_WIN='D:\Pacific_doorlock\从零开始认识裁判系统\RoboMasterClient 12.0.0.213_Student\RoboMasterClient 12.0.0.213_Student\RoboMasterClient'
WIN_EXE_WIN="$WIN_DIR_WIN\\RoboMasterClient.exe"
PWSH='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

# --- 图传 daemon（打开 COM5 + 图传 USB，cuda 硬解，写共享内存给官方选手端）---
WIN_DAEMON_DIR_WIN="$WIN_DIR_WIN\\RoboMasterClient_Data\\StreamingAssets\\Tools\\RMClientDaemon"
WIN_DAEMON_EXE_WIN="$WIN_DAEMON_DIR_WIN\\RMClientDaemon.exe"


# --- 引擎装甲日志（受击方向只有这个来源） ----------------------------------
ENGINE_LOG_DIR='/mnt/d/Pacific_doorlock/从零开始认识裁判系统/RoboMasterEngine 12.0.0.176_Student/RoboMasterEngine 12.0.0.176_Student/RoboMasterEngine_Data/StreamingAssets/RMServer/RMServerLogClient/RM裁判系统日志文件夹3.0'

MQTT_PORT=3333
BROKER_WAIT_SEC=25   # 官方选手端启动到监听 3333 约需 8 秒，留足余量

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

# ============================================================================
# 0. 前置检查
# ============================================================================
preflight() {
  step "0/6 前置检查"

  if [ ! -f "$CONFIG" ]; then
    warn "找不到 $CONFIG"
    say  "  先执行一次：bash $REPO/test/mkconfig.sh"
    exit 1
  fi
  ok "config.json 就位"

  if [ ! -x "$CLIENT_EXE" ]; then
    warn "自定义客户端还没构建：$CLIENT_EXE"
    say  "  先执行：bash $REPO/test/build.sh"
    exit 1
  fi
  ok "自定义客户端已构建"

  if [ ! -f "$WIN_DIR/RoboMasterClient.exe" ]; then
    warn "找不到官方选手端：$WIN_DIR_WIN"
    exit 1
  fi
  ok "官方选手端就位"
}

# ============================================================================
# 1. 稳定本机
# ============================================================================
stabilize_local() {
  step "1/6 稳定本机"

  # 1a. 内核 UDP 接收缓冲。客户端请求 8MB，内核默认 208KB 会被静默截断，
  #     表现为图传每几秒卡一次（等关键帧）。必须 >= 16MB。
  local cur
  cur=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
  if [ "$cur" -ge 16777216 ] 2>/dev/null; then
    ok "UDP 接收缓冲 rmem_max=$cur"
  elif sudo -n sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1; then
    ok "UDP 接收缓冲已调大到 16777216"
  else
    warn "rmem_max=$cur 偏小，图传会周期性卡顿；需要 root，手动执行一次："
    say  "      sudo sysctl -w net.core.rmem_max=16777216"
  fi

  # 1b. 杀残留客户端。注意 Linux 进程名截断到 15 字符，
  #     进程实际叫 RoboMasterClien，用全名 pkill 会静默失败，
  #     导致新旧实例抢同一个 ClientId（表现为 CONNACK(2) Identifier rejected）。
  if pgrep -x RoboMasterClien >/dev/null 2>&1; then
    warn "发现残留的自定义客户端，清理掉以免抢 ClientId"
    pgrep -x RoboMasterClien | xargs -r kill -9
    sleep 1
  fi
  ok "无残留客户端"
}

# ============================================================================
# 2. 稳定寻址
# ============================================================================
point_config_to_host() {
  step "2/6 把 config 指向 Windows 主机"

  WINIP=$(ip route | awk '/^default/{print $3}')
  if [ -z "${WINIP:-}" ]; then
    warn "拿不到 Windows 主机 IP（ip route 没有 default）"
    exit 1
  fi

  python3 - "$UPSTREAM" "$WINIP" <<'PY'
import json, os, sys
upstream, ip = sys.argv[1], sys.argv[2]
path = os.path.join(upstream, 'config.json')
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['network']['server_ip'] = ip
cfg['network']['mqtt_broker'] = ip
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=4)
PY
  ok "broker = $WINIP:$MQTT_PORT"
}

# ============================================================================
# 3. 图传 daemon（必须在官方选手端之前）
# ============================================================================
# 链路：图传模块 → RMClientDaemon（COM5 + 图传 USB，cuda 硬解）→ 共享内存 → 官方选手端窗口。
# daemon 不在，官方选手端只显示"图传未接入"，一个错都不报。
# 反过来先起客户端再起 daemon，共享内存对不上，也必须重启客户端。
daemon_alive() {
  "$PWSH" -NoProfile -Command \
    "if (Get-Process RMClientDaemon -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" \
    >/dev/null 2>&1
}

client_alive() {
  "$PWSH" -NoProfile -Command \
    "if (Get-Process RoboMasterClient -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" \
    >/dev/null 2>&1
}

kill_daemon() {
  "$PWSH" -NoProfile -Command \
    "foreach (\$n in 'RMClientDaemon','RMClientAssist_VideoRecord','RMClientAssist_MarkRecognition','RMClientAssist_SerialPort','RMClientAssist_RemoteSerialPort') { Get-Process -Name \$n -ErrorAction SilentlyContinue | Stop-Process -Force }" \
    >/dev/null 2>&1
  sleep 2
}

start_video_daemon() {
  step "3/6 图传 daemon（COM5 + 图传 USB）"

  local dji
  dji=$("$PWSH" -NoProfile -Command \
    "(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_2CA3' -and \$_.Class -eq 'Ports' } | ForEach-Object { \$_.FriendlyName }) -join ', '" \
    2>/dev/null | tr -d '\r')
  if [ -z "$dji" ]; then
    warn "Windows 没枚举到 DJI 图传接收端（VID_2CA3 / COM5 / COM8）"
    warn "接收端没插好就不会有画面；插好后重跑本脚本"
  else
    ok "图传接收端：$dji"
  fi

  if daemon_alive; then
    ok "daemon 已在运行，复用"
  else
    if client_alive; then
      warn "官方选手端先于 daemon 起来了，共享内存对不上 —— 重启官方选手端"
      "$PWSH" -NoProfile -Command \
        "Stop-Process -Name RoboMasterClient -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
      sleep 2
    fi

    kill_daemon
    say "  启动 RMClientDaemon ..."
    "$PWSH" -NoProfile -Command \
      "Start-Process -FilePath '$WIN_DAEMON_EXE_WIN' -WorkingDirectory '$WIN_DAEMON_DIR_WIN'" \
      >/dev/null 2>&1
    sleep 6

    if daemon_alive; then
      ok "daemon 进程已起"
    else
      warn "daemon 没起来：$WIN_DAEMON_EXE_WIN"
      warn "官方选手端可以照常登录拿数据，但不会有图传画面"
    fi
  fi

  # 验收：daemon 会往 realtimelog_SerialPort 写一串关键行
  #   初始化图传解码dll成功 / 硬件解码器初始化成功: cuda / 打开video2015串口:COM5 / 打开图传USB设备成功
  local serdir="$WIN_DIR/RoboMasterClient_Data/StreamingAssets/Tools/RMClientDaemon/realtimelog_SerialPort"
  local newest
  newest=$(ls -t "$serdir"/*.txt 2>/dev/null | head -1)
  if [ -z "$newest" ]; then
    warn "realtimelog_SerialPort 里没有任何日志 —— daemon 从没成功跑过"
  elif [ -n "$(find "$newest" -mmin -2 2>/dev/null)" ]; then
    ok "daemon 正在写串口日志：$(basename "$newest")"
    local hit
    hit=$(grep -a -c 'video2015' "$newest" 2>/dev/null || echo 0)
    if [ "$hit" -gt 0 ]; then
      ok "video2015 串口已打开（命中 $hit 行）"
    else
      warn "日志里没有 video2015 —— 串口没打开，检查 COM5 是否被别的程序占用"
    fi
    say "  最近 2 条："
    grep -a 'video2015\|图传USB\|cuda' "$newest" 2>/dev/null | tail -2 | sed 's/^/      /'
  else
    warn "最新的串口日志不是本次产生的：$(basename "$newest")"
    warn "daemon 可能启动即退出，看 RMClientDaemon/realtimelog_daemonself/ 里的报错"
  fi
}

# ============================================================================
# 4. 官方选手端（= MQTT broker）
# ============================================================================
broker_up() {
  python3 - "$1" "$MQTT_PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(1.5)
sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PY
}

wait_broker() {
  local timeout="$1" i
  for ((i = 0; i < timeout; i++)); do
    broker_up "$WINIP" && return 0
    sleep 1
  done
  return 1
}

launch_official_client() {
  local elevate="${1:-0}" verb=""
  [ "$elevate" = "1" ] && verb="-Verb RunAs"
  # 用 -LiteralPath 语义传路径，中文目录在 WSL→PowerShell 之间不会乱码
  "$PWSH" -NoProfile -Command \
    "Start-Process -FilePath '$WIN_EXE_WIN' -WorkingDirectory '$WIN_DIR_WIN' $verb" \
    >/dev/null 2>&1
}

ensure_broker() {
  step "4/6 官方选手端（MQTT broker）"

  if broker_up "$WINIP"; then
    ok "broker 已在 $WINIP:$MQTT_PORT 监听，跳过启动"
    return 0
  fi

  say "  启动官方选手端（免提权）..."
  launch_official_client 0
  if wait_broker "$BROKER_WAIT_SEC"; then
    ok "broker 就绪（$WINIP:$MQTT_PORT）"
    return 0
  fi

  # 免提权没起来，通常就是 Login.bin 写不进去（目录 ACL 未授权）。
  # 兜底再试一次提权启动；想彻底免掉这一步就跑 --fix-acl。
  warn "免提权启动后 broker 仍没监听，改用管理员权限再试（会弹 UAC）"
  launch_official_client 1
  if wait_broker "$BROKER_WAIT_SEC"; then
    ok "broker 就绪（$WINIP:$MQTT_PORT）"
    warn "建议执行一次 'bash $SELF --fix-acl'，以后就不用再弹 UAC"
    return 0
  fi

  warn "官方选手端起来了但 3333 没监听。常见原因："
  say  "      · 裁判系统栈没起（RMServer / AdapterSvrS0 / RMServerLogClient / RoboMasterEngine）"
  say  "      · 客户端停在登录界面没点进去"
  say  "      · 免提权导致写不了 Login.bin —— 跑一次 $SELF --fix-acl"
  exit 1
}

# ============================================================================
# 5. ClientId 占用检查
# ============================================================================
check_client_id() {
  local cid="$1"
  python3 - "$REPO/test" "$WINIP" "$MQTT_PORT" "$cid" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from mqtt_probe import mqtt_connect
host, port, cid = sys.argv[2], int(sys.argv[3]), sys.argv[4]
code, err = mqtt_connect(host, port, cid)
if code is None:
    print(f"  \033[33m⚠ 握手失败：{err}\033[0m"); sys.exit(2)
if code == 0:
    print(f"  \033[32m✓ ClientId {cid} 空闲\033[0m"); sys.exit(0)
if code == 2:
    print(f"  \033[33m⚠ ClientId {cid} 已被占用（别的客户端/桥接进程还连着）\033[0m")
    sys.exit(1)
print(f"  \033[33m⚠ ClientId {cid} 被拒，返回码 {code}\033[0m"); sys.exit(1)
PY
}

# ============================================================================
# 5. 启动自定义客户端
# ============================================================================
start_custom_client() {
  step "5/6 启动自定义客户端"

  local cid
  cid=$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8'))['network'].get('client_robot_id',1))
" "$CONFIG" 2>/dev/null)
  cid="${RM_CLIENT_ROBOT_ID:-$cid}"

  # 同一个 ClientId 同时只能有一个连接；被占着的话连上也拿不到数据，
  # 这里提前说清楚，省得看着黑屏猜。
  check_client_id "$cid" || warn "仍会尝试启动，但很可能收到 Identifier rejected"

  if [ -d "$ENGINE_LOG_DIR" ]; then
    export RM_ENGINE_ARMOR_LOG_DIR="$ENGINE_LOG_DIR"
    ok "受击方向：已挂引擎日志目录"
  else
    warn "引擎日志目录不存在，受击方向将没有数据（其余功能不受影响）"
  fi

  # 客户端实际从构建目录加载 config.json；源 config 已被 point_config_to_host
  # 改过，但构建目录里的副本可能是旧的。用环境变量强制指向当前 Windows 主机。
  export RM_MQTT_BROKER="$WINIP"
  export RM_MQTT_PORT="$MQTT_PORT"

  say ""
  say "  启动中（Ctrl+C 退出）..."
  cd "$BUILD" || exit 1
  exec ./RoboMasterClient2025
}

# ============================================================================
# --fix-acl：一次性授权，让 ty 免管理员启动官方选手端
# ============================================================================
fix_acl() {
  step "一次性授权：让当前用户可写官方选手端目录"
  local winuser
  winuser=$("$PWSH" -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r\n')
  if [ -z "$winuser" ]; then
    warn "拿不到 Windows 用户名"; exit 1
  fi
  say "  授权对象：$winuser"
  say "  目标目录：$WIN_DIR_WIN"
  say "  接下来会弹一次 UAC，点是即可。"
  # icacls 用管理员跑；/T 递归到子目录，/grant 给 Modify 权限
  "$PWSH" -NoProfile -Command \
    "Start-Process -FilePath 'icacls.exe' -ArgumentList '\"$WIN_DIR_WIN\"','/grant','\"$winuser:(OI)(CI)M\"','/T' -Verb RunAs -Wait" \
    >/dev/null 2>&1
  ok "已提交授权（若 UAC 被取消则未生效）。之后直接跑 run.sh 即可，不再需要管理员。"
}

# ============================================================================
# 主流程
# ============================================================================
case "${1:-}" in
  --fix-acl) fix_acl; exit 0 ;;
  -h|--help) sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

preflight
stabilize_local
point_config_to_host
start_video_daemon
ensure_broker
start_custom_client
