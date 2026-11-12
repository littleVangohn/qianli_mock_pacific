#!/bin/bash
# ============================================================================
# 构建自定义客户端，产物落在 ~/rm26-build/RoboMasterClient2025
#
#   bash <仓库>/test/build.sh
#
# 源码路径从本脚本位置推导，所以仓库改名/搬家都不用改这里。
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(dirname "$(dirname "$SELF")")"   # 本脚本在 test/ 下，上一层才是仓库根
SRC="$REPO/upstream"
BUILD="${RM26_BUILD_DIR:-$HOME/rm26-build}"

# 仓库改名或搬家后，CMakeCache 里记的源码目录就失效了，cmake 会直接报错退出。
# 这里先比对缓存，不一致就整个清掉重新配置，省得手动 rm -rf。
CACHE="$BUILD/CMakeCache.txt"
if [ -f "$CACHE" ]; then
  cached=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE" | head -1)
  if [ -n "$cached" ] && [ "$cached" != "$SRC" ]; then
    echo "源码目录已变更："
    echo "  缓存里: $cached"
    echo "  现在  : $SRC"
    echo "清掉旧缓存重新配置..."
    rm -rf "$BUILD"
  fi
fi

echo "=== 配置 ==="
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DRM_VALIDATE_ASSETS=OFF || exit 1

echo
echo "=== 编译 ==="
time cmake --build "$BUILD" -j"$(nproc)" || exit 1

echo
echo "=== 产物 ==="
ls -la "$BUILD/RoboMasterClient2025"
