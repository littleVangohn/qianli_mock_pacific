#!/bin/bash
echo "=== 构建工具 ==="
for t in cmake ninja g++ pkg-config git; do
  printf "  %-12s " "$t"
  if command -v "$t" >/dev/null 2>&1; then "$t" --version 2>&1 | head -1; else echo "未装"; fi
done
echo
echo "=== 库 (pkg-config) ==="
for p in Qt6Core Qt6Gui Qt6Widgets Qt6Quick Qt6QuickControls2 Qt6QuickWidgets Qt6Multimedia Qt6SerialPort Qt6Svg protobuf libavcodec libavformat libavutil libswscale libpaho-mqtt3c; do
  printf "  %-22s " "$p"
  if pkg-config --exists "$p" 2>/dev/null; then pkg-config --modversion "$p"; else echo "未装"; fi
done
echo
echo "=== abseil (cmake config) ==="
ls -d /usr/lib/x86_64-linux-gnu/cmake/absl 2>/dev/null && echo "  absl cmake config 存在" || echo "  absl cmake config 未找到"
