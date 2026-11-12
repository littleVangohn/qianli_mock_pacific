#!/bin/bash
# ============================================================================
# 恶劣环境扫描：在一个个劣化场景下重复测同一套指标
#
#   bash <仓库>/test/jitter/run_sweep.sh 1     # 链路劣化（约 5 分钟）
#   bash <仓库>/test/jitter/run_sweep.sh 2     # 连接级打击（约 6 分钟）
#   bash <仓库>/test/jitter/run_sweep.sh all
#
# 每个场景跑完就地出报告；全部跑完再出一张横向对比表（summarize.py）。
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIER="${1:-1}"

run_one() {
  local name="$1" dur="$2"; shift 2
  printf '\n\033[1m############################################################\033[0m\n'
  printf '\033[1m# 场景 %-10s  时长 %ss   参数: %s\033[0m\n' "$name" "$dur" "$*"
  printf '\033[1m############################################################\033[0m\n'
  JITTER_LABEL="$name" JITTER_BROKER_ARGS="$*" bash "$HERE/run_baseline.sh" "$dur"
}

tier1() {
  # 链路劣化：丢包、成串丢包、延迟抖动、重复
  run_one loss1     45 "--drop-rate 0.01"
  run_one loss5     45 "--drop-rate 0.05"
  run_one burst     45 "--burst-gb 0.01 --burst-bg 0.3"
  run_one delay     45 "--delay-ms 60 --delay-jitter-ms 40"
  run_one dup       45 "--dup-rate 0.05"
}

tier2() {
  # 连接级打击：假死、闪断、组合重击
  run_one freeze    60 "--scenario freeze@20+10"
  run_one blackhole 90 "--scenario blackhole@20+25"
  run_one reset     70 "--scenario reset@25"
  run_one hell      90 "--drop-rate 0.02 --delay-ms 30 --delay-jitter-ms 20 --scenario blackhole@30+12,reset@60"
}

case "$TIER" in
  1)   tier1 ;;
  2)   tier2 ;;
  all) tier1; tier2 ;;
  *)   echo "用法: $0 [1|2|all]"; exit 1 ;;
esac

printf '\n\033[1m=== 横向对比 ===\033[0m\n'
python3 "$HERE/summarize.py"
