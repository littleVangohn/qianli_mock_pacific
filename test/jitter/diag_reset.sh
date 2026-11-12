#!/bin/bash
# ============================================================================
# 诊断：reset 之后客户端到底怎么了
#
#   bash diag_reset.sh [reset时刻，默认25]
#
# 不改任何客户端代码，只从外部观察：
#   - /proc/<pid>/stat 的 utime+stime → CPU 是否还在跑（死锁会塌到 0）
#   - /proc/<pid>/status 的 Threads → 线程是否还在
#   - broker 侧的存活探针（客户端上行发包数）→ 是否还在发
# 三者合起来能区分「UI 线程死锁」「进程活着但不发包」「进程死了」。
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${RM26_BUILD_DIR:-$HOME/rm26-build}"
PORT=13338
RESET_AT="${1:-25}"
DURATION=$((RESET_AT + 45))
OUT="$HERE/out/diag-$(date +%H%M%S)"
mkdir -p "$OUT"

HZ=$(getconf CLK_TCK)

pgrep -x RoboMasterClien >/dev/null 2>&1 && pgrep -x RoboMasterClien | xargs -r kill -9

python3 "$HERE/mock_broker.py" --port "$PORT" --out-dir "$OUT" \
        --duration $((DURATION + 15)) --scenario "reset@$RESET_AT" > "$OUT/broker.log" 2>&1 &
BPID=$!
sleep 1.5

(
  cd "$BUILD" || exit 1
  export RM_MQTT_BROKER=127.0.0.1 RM_MQTT_PORT="$PORT" RM_CLIENT_ROBOT_ID=1
  exec ./RoboMasterClient2025
) > "$OUT/client.stdout" 2>&1 &
CPID=$!
sleep 2

echo "客户端 PID=$CPID  (reset 发生在 +${RESET_AT}s)"
printf '%8s %10s %10s %8s\n' "时刻(s)" "CPU累计(ms)" "间隔CPU(ms)" "线程数"

prev=0
t0=$(date +%s%N)
for i in $(seq 1 $((DURATION / 3))); do
  sleep 3
  [ -d "/proc/$CPID" ] || { echo "  —— 进程已退出 ——"; break; }
  read -r ut st < <(awk '{print $14, $15}' "/proc/$CPID/stat" 2>/dev/null)
  [ -z "${ut:-}" ] && break
  tot=$(( (ut + st) * 1000 / HZ ))
  thr=$(awk '/^Threads:/{print $2}' "/proc/$CPID/status" 2>/dev/null)
  now=$(( ($(date +%s%N) - t0) / 1000000000 ))
  printf '%8s %10s %10s %8s\n' "$now" "$tot" "$((tot - prev))" "$thr"
  prev=$tot
done

kill -TERM "$CPID" 2>/dev/null; sleep 1
kill -TERM "$BPID" 2>/dev/null; sleep 0.5
echo
echo "存活探针（broker 侧看到的上行包数）："
python3 /mnt/c/Users/ty/AppData/Local/Temp/lv.py "$OUT/events.jsonl" 2>/dev/null | grep -E "liveness|reset|connect|disconnect" | tail -16
echo
echo "产物: $OUT"
