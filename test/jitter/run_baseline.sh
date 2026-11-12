#!/bin/bash
# ============================================================================
# 基线采集：起离线 broker → 起客户端 → 跑一段 → 收尾 → 出性能参数
#
#   bash <仓库>/test/jitter/run_baseline.sh [秒数，默认 60]
#
# 全程不碰仓库里任何既有文件：
#   * broker 地址用环境变量 RM_MQTT_BROKER / RM_MQTT_PORT 覆盖，不改 config.json
#   * 不启动裁判系统栈、不启动官方选手端、不需要真实主控
#   * 只新增文件，全部落在 test/jitter/out/<时间戳>/
#
# 环境变量：
#   JITTER_PORT       broker 端口（默认 13333，避开官方选手端的 3333）
#   RM26_BUILD_DIR    客户端构建目录（默认 ~/rm26-build）
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
REPO="$(dirname "$(dirname "$HERE")")"
BUILD="${RM26_BUILD_DIR:-$HOME/rm26-build}"
EXE="$BUILD/RoboMasterClient2025"

PORT="${JITTER_PORT:-13333}"
DURATION="${1:-60}"
# 交给 broker 的故障参数，由 run_sweep.sh 之类注入；默认空 = 健康链路
EXTRA_ARGS="${JITTER_BROKER_ARGS:-}"
OUT="$HERE/out/$(date +%Y%m%d-%H%M%S)${JITTER_LABEL:+-$JITTER_LABEL}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }

port_open() {
  python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(); s.settimeout(0.5)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}

BROKER_PID=""
CLIENT_PID=""
cleanup() {
  [ -n "$CLIENT_PID" ] && kill -TERM "$CLIENT_PID" 2>/dev/null
  [ -n "$BROKER_PID" ] && kill -TERM "$BROKER_PID" 2>/dev/null
  sleep 0.5
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
step "0/4 前置检查"
[ -x "$EXE" ] || { warn "找不到客户端：$EXE（先跑 test/build.sh）"; exit 1; }
ok "客户端 $EXE"
python3 -c "import google.protobuf, sys; sys.path.insert(0,'$REPO/upstream/sim'); import robomaster_pb2" 2>/dev/null \
  || { warn "缺 protobuf 或 robomaster_pb2 导入失败"; exit 1; }
ok "protobuf 与协议定义可用"
mkdir -p "$OUT"

# 清掉可能残留的客户端——它占着 ClientId，会让新实例连不上
if pgrep -x RoboMasterClien >/dev/null 2>&1; then
  warn "清理残留客户端"
  pgrep -x RoboMasterClien | xargs -r kill -9
  sleep 1
fi

# ---------------------------------------------------------------------------
step "1/4 启动离线 broker (127.0.0.1:$PORT)"
# shellcheck disable=SC2086
python3 "$HERE/mock_broker.py" --port "$PORT" --out-dir "$OUT" \
        --duration $((DURATION + 20)) $EXTRA_ARGS > "$OUT/broker.log" 2>&1 &
BROKER_PID=$!

for _ in $(seq 1 40); do
  port_open "$PORT" && break
  sleep 0.25
done
port_open "$PORT" || { warn "broker 没起来，看 $OUT/broker.log"; exit 1; }
ok "broker 就绪，发布计划：CustomByteBlock 50Hz + 5 个比赛 topic"

# ---------------------------------------------------------------------------
step "2/4 启动客户端（指向离线 broker，采集 ${DURATION}s）"
START_TS=$(date +%s)
(
  cd "$BUILD" || exit 1
  export RM_MQTT_BROKER=127.0.0.1
  export RM_MQTT_PORT="$PORT"
  export RM_CLIENT_ROBOT_ID=1
  exec ./RoboMasterClient2025
) > "$OUT/client.stdout" 2>&1 &
CLIENT_PID=$!
ok "客户端 PID=$CLIENT_PID，等待 ${DURATION}s ..."

sleep "$DURATION"

kill -TERM "$CLIENT_PID" 2>/dev/null
sleep 1.5
CLIENT_PID=""
ok "客户端已停止"

# ---------------------------------------------------------------------------
step "3/4 定位客户端日志"
RUNTIME_LOG=$(find "$BUILD/tmp" -name runtime.log -newermt "@$START_TS" 2>/dev/null | sort | tail -1)
if [ -z "$RUNTIME_LOG" ]; then
  RUNTIME_LOG=$(ls -t "$BUILD"/tmp/runtime_*/runtime.log 2>/dev/null | head -1)
fi
[ -n "$RUNTIME_LOG" ] || { warn "找不到 runtime.log"; exit 1; }
ok "$RUNTIME_LOG"
cp -f "$RUNTIME_LOG" "$OUT/runtime.log" 2>/dev/null

# ---------------------------------------------------------------------------
step "4/4 分析"
python3 "$HERE/analyze.py" --out-dir "$OUT" --runtime-log "$OUT/runtime.log"

say ""
say "原始产物：$OUT"
