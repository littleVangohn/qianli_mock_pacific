#!/bin/bash
# ============================================================================
# 首次生成 config.json（已存在则不动它）
#
#   bash <仓库>/test/mkconfig.sh
#
# 源码路径从本脚本位置推导，所以仓库改名/搬家都不用改这里。
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(dirname "$(dirname "$SELF")")"   # 本脚本在 test/ 下，上一层才是仓库根
SRC="$REPO/upstream"

cd "$SRC" || exit 1
if [ -f config.json ]; then
  echo "config.json 已存在，不动它"
else
  cp config.example.json config.json
  echo "已生成 config.json（复制自 example）"
fi
echo
echo "=== 关键字段 ==="
python3 -c "
import json
c=json.load(open('config.json',encoding='utf-8'))
n=c['network']; v=c['video']
for k in ('server_ip','server_port','client_port','video_port','mqtt_broker','mqtt_port','client_robot_id'):
    print('  network.%-18s %s' % (k, n.get(k)))
print('  video.stream_url%-20s %s' % ('', v.get('stream_url')))
"
echo
echo "=== 跑官方示例检查器 ==="
python3 tools/release/check_example_config.py config.json 2>&1 | tail -15
