#!/usr/bin/env python3
"""把 QML 里的 `pragma ComponentBehavior: Bound` 注释掉，让 Qt 6.2 能解析。

背景：该 pragma 是 Qt 6.5 引入的，本机 Qt 6.2.4 会在解析阶段直接报
      "Expected token ';'"，导致含它的组件全部加载失败（表现为黑屏）。

为什么这个改动是安全的：
  - 该 pragma 的作用是把组件切到 Bound 行为；不写就是 Unbound（Qt 6.2 唯一的模式）。
  - 为 Bound 写的代码必须显式把属性传进 delegate（required property），
    这种写法在 Unbound 下同样有效 —— Bound 是 Unbound 的受限子集。

用法：
  python3 patch_qml_qt62.py apply     # 注释掉 pragma（先自动备份）
  python3 patch_qml_qt62.py revert    # 从备份还原
  python3 patch_qml_qt62.py status    # 看当前状态
"""
import shutil
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent

# 本脚本归档在 test/ 下，upstream/ 在上一层；写成"向上找"的写法，
# 这样脚本无论放在仓库根目录还是 test/ 里都能定位到源码。
_REPO = next((p for p in (_HERE, *_HERE.parents)
              if (p / "upstream" / "src" / "qml").is_dir()), _HERE.parent)
ROOT = _REPO / "upstream" / "src" / "qml"
# 备份始终跟着脚本走（与 _patches/ 同在 test/ 下）
BACKUP = _HERE / "_patches" / "qml-pragma-backup"

MARK = "// [Qt6.2 patch]"
PRAGMA = "pragma ComponentBehavior: Bound"


def has_live_pragma(text: str) -> bool:
    """判断文件里是否存在**未被注释**的 pragma。

    不能简单用 `PRAGMA in text` —— 打补丁后的注释行里同样含有这串文字
    （`// [Qt6.2 patch] pragma ComponentBehavior: Bound ...`），那样会把
    已处理的文件误判成未处理，重复执行 apply 还会把注释本身再替换一遍。
    """
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        if stripped.startswith(PRAGMA):
            return True
    return False


def qml_files():
    return sorted(p for p in ROOT.rglob("*.qml")
                  if has_live_pragma(p.read_text(encoding="utf-8")))


def apply():
    files = qml_files()
    if not files:
        print("没有需要处理的文件（可能已经打过补丁）")
        return
    BACKUP.mkdir(parents=True, exist_ok=True)
    for f in files:
        rel = f.relative_to(ROOT)
        dst = BACKUP / rel
        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
        text = f.read_text(encoding="utf-8")
        text = text.replace(
            PRAGMA,
            f"{MARK} {PRAGMA} —— 需 Qt 6.5+，本机 Qt 6.2.4 不支持，暂时注释",
        )
        f.write_text(text, encoding="utf-8")
        print(f"  已处理 {rel}")
    print(f"\n共 {len(files)} 个文件，原件备份在 {BACKUP}")


def revert():
    if not BACKUP.exists():
        print("没有备份，无法还原")
        return
    n = 0
    for src in sorted(BACKUP.rglob("*.qml")):
        dst = ROOT / src.relative_to(BACKUP)
        shutil.copy2(src, dst)
        print(f"  已还原 {src.relative_to(BACKUP)}")
        n += 1
    print(f"\n共还原 {n} 个文件")


def status():
    patched = [p for p in ROOT.rglob("*.qml") if MARK in p.read_text(encoding="utf-8")]
    raw = qml_files()
    print(f"  已打补丁: {len(patched)}")
    print(f"  未处理  : {len(raw)}")
    if raw:
        for p in raw:
            print(f"    - {p.relative_to(ROOT)}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    print(f"QML 根目录: {ROOT}\n")
    {"apply": apply, "revert": revert, "status": status}.get(cmd, status)()
