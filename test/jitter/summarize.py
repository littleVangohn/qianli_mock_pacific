#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 out/ 下所有跑过的场景汇成一张横向对比表。

用法：
  python3 summarize.py [--out-root <目录>]
"""

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def short_label(dirname: str) -> str:
    # 目录名形如 20261015-010203-loss5，取时间戳后面那段
    parts = dirname.split("-", 2)
    return parts[2] if len(parts) > 2 else "(baseline)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-root", default=os.path.join(_HERE, "out"))
    args = ap.parse_args()

    rows = []
    for name in sorted(os.listdir(args.out_root)):
        mpath = os.path.join(args.out_root, name, "metrics.json")
        if not os.path.exists(mpath):
            continue
        try:
            with open(mpath, encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        cb = m.get("topics", {}).get("CustomByteBlock", {})
        rows.append({
            "label": short_label(name),
            "dir": name,
            "loss": m.get("cb_loss_rate_effective", m.get("cb_loss_rate")),
            "dup": m.get("cb_dup_rate"),
            "reorder": m.get("cb_reorder_rate"),
            "avail": m.get("availability_300ms"),
            "worst_gap_s": (m.get("worst_gap_ms") or 0) / 1000.0,
            "reconn": m.get("reconnects", 0),
            "j": cb.get("jitter_J_ms"),
            "p99": cb.get("ipi_p99_ms"),
            "hz": cb.get("hz"),
        })

    if not rows:
        print("  (还没有任何 metrics.json)")
        return

    hdr = (f"{'场景':<12}{'丢包率':>9}{'重复率':>9}{'乱序率':>9}"
           f"{'可用率':>10}{'最长中断':>10}{'重连':>6}{'抖动J':>7}{'p99':>6}{'Hz':>7}")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        def f(v, scale=1.0, unit="", nd=3):
            return "-" if v is None else f"{v * scale:.{nd}f}{unit}"
        print(f"{r['label']:<12}"
              f"{f(r['loss'], 100, '%'):>9}"
              f"{f(r['dup'], 100, '%'):>9}"
              f"{f(r['reorder'], 100, '%'):>9}"
              f"{f(r['avail'], 100, '%'):>10}"
              f"{r['worst_gap_s']:>9.2f}s"
              f"{r['reconn']:>6}"
              f"{f(r['j'], 1, '', 0):>7}"
              f"{f(r['p99'], 1, '', 0):>6}"
              f"{f(r['hz'], 1, '', 1):>7}")


if __name__ == "__main__":
    main()
