#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
基线分析器：把 mock_broker 的发送记录与客户端 runtime.log 对起来，算出性能参数。

配对方式（关键）：不靠时间猜。
  broker 侧  sent.jsonl 记了每条消息的载荷 → 本地算 sha1
  客户端侧  RM26_MQTT_RX_TIMING 每行带 sha1
  两者按 sha1 精确相认，于是"发出去的"和"收到的"能一一对上，
  丢没丢、丢哪条、延迟多少都是确定的，不是统计推测。

用法：
  python3 analyze.py --out-dir <broker的输出目录> --runtime-log <runtime.log路径>
"""

import argparse
import collections
import hashlib
import json
import os
import re
import sys
from datetime import datetime

RX_RE = re.compile(
    r"RM26_MQTT_RX_TIMING direction=rx topic=(\S+) received_ms=(\d+) bytes=(\d+) sha1=([0-9a-fA-F]+)")
LINE_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})")
PARSED_RE = re.compile(r"Parsed custom data for robot (\d+) seq=(\d+)")

CB_TOPIC = "CustomByteBlock"


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, max(0, int(round(p * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


def parse_log_time(s):
    try:
        return int(datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000)
    except ValueError:
        return None


def load_sent(path):
    """→ {sha1: [记录...]}，并保留时间序列表。"""
    by_sha = collections.defaultdict(list)
    ordered = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            ordered.append(r)
    return ordered, by_sha


def load_events(path):
    evs = []
    if not os.path.exists(path):
        return evs
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                evs.append(json.loads(line))
    return evs


def load_runtime(path):
    """→ (rx_records, parsed_records)。rx: topic/received_ms/bytes/sha1/log_ms"""
    rx, parsed = [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = RX_RE.search(line)
            if m:
                ts = LINE_TS_RE.match(line)
                rx.append({
                    "topic": m.group(1),
                    "received_ms": int(m.group(2)),
                    "bytes": int(m.group(3)),
                    "sha1": m.group(4).lower(),
                    "log_ms": parse_log_time(ts.group(1)) if ts else None,
                })
                continue
            m = PARSED_RE.search(line)
            if m:
                ts = LINE_TS_RE.match(line)
                parsed.append({
                    "robot": int(m.group(1)),
                    "seq": int(m.group(2)),
                    "log_ms": parse_log_time(ts.group(1)) if ts else None,
                })
    return rx, parsed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--runtime-log", required=True)
    args = ap.parse_args()

    sent_path = os.path.join(args.out_dir, "sent.jsonl")
    if not os.path.exists(sent_path):
        sys.exit(f"找不到 {sent_path}")
    if not os.path.exists(args.runtime_log):
        sys.exit(f"找不到 {args.runtime_log}")

    sent = load_sent(sent_path)[0]
    events = load_events(os.path.join(args.out_dir, "events.jsonl"))
    rx, parsed = load_runtime(args.runtime_log)

    report = {}
    print("=" * 68)
    print("基线测量报告")
    print("=" * 68)

    # ---------------- 连接建立 ----------------
    conns = [e for e in events if e["event"] == "connect"]
    subs = [e for e in events if e["event"] == "subscribe"]
    print("\n[连接]")
    if conns:
        c = conns[0]
        print(f"  客户端连接        {c['client_id']}  (MQTT level {c.get('mqtt_level')}, "
              f"keepalive {c.get('keepalive')}s)")
    if subs:
        # 客户端是逐个 topic 订阅的（一个 topic 一个 SUBSCRIBE 包），必须累加，
        # 只看 subs[0] 会误报成"只订阅了 1 个"。
        all_topics = set()
        for e in subs:
            all_topics.update(e["topics"])
        first_dt = subs[0]["t_ms"] - conns[0]["t_ms"] if conns else None
        last_dt = subs[-1]["t_ms"] - conns[0]["t_ms"] if conns else None
        print(f"  订阅 topic        {len(all_topics)} 个，分 {len(subs)} 个 SUBSCRIBE 包")
        if first_dt is not None:
            print(f"  订阅耗时          CONNECT 后 {first_dt} → {last_dt} ms")
        report["subscribed_topics"] = len(all_topics)
        report["subscribe_packets"] = len(subs)
        report["subscribe_done_ms"] = last_dt

    if not rx:
        print("\n⚠ 没有收到任何 RM26_MQTT_RX_TIMING —— 客户端可能没连上或没解析成功")
        sys.exit(2)

    # ---------------- 全局窗口 ----------------
    all_rx_ms = [r["received_ms"] for r in rx]
    t_first, t_last = min(all_rx_ms), max(all_rx_ms)
    span_s = (t_last - t_first) / 1000.0
    print(f"\n[窗口]  首包→末包 {span_s:.1f} s，共 {len(rx)} 条 RX 记录")
    report["window_s"] = round(span_s, 3)
    report["rx_records"] = len(rx)

    if subs and conns:
        report["connect_to_first_msg_ms"] = t_first - conns[0]["t_ms"]
        print(f"  CONNECT → 首包     {t_first - conns[0]['t_ms']} ms")

    # ---------------- 分 topic 的到达间隔 ----------------
    print(f"\n[各 topic 到达间隔]  (只统计窗口内的)")
    by_topic = collections.defaultdict(list)
    for r in rx:
        by_topic[r["topic"]].append(r["received_ms"])

    print(f"  {'topic':<24}{'条数':>7}{'Hz':>8}{'p50':>9}{'p95':>9}{'p99':>9}{'max':>9}{'抖动J':>9}")
    topic_stats = {}
    for topic, arr in sorted(by_topic.items(), key=lambda kv: -len(kv[1])):
        arr.sort()
        if len(arr) < 3:
            continue
        ipi = sorted(b - a for a, b in zip(arr, arr[1:]))
        p50, p95, p99 = pct(ipi, 0.50), pct(ipi, 0.95), pct(ipi, 0.99)
        st = {
            "n": len(arr), "hz": round(len(arr) / span_s, 2) if span_s else None,
            "ipi_p50_ms": p50, "ipi_p95_ms": p95, "ipi_p99_ms": p99,
            "ipi_max_ms": ipi[-1], "jitter_J_ms": (p95 - p50) if p95 and p50 else None,
        }
        topic_stats[topic] = st
        print(f"  {topic:<24}{st['n']:>7}{st['hz']:>8.2f}{p50:>9}{p95:>9}{p99:>9}"
              f"{ipi[-1]:>9}{st['jitter_J_ms']:>9}")
    report["topics"] = topic_stats

    # ---------------- CustomByteBlock 端到端核对 ----------------
    print(f"\n[{CB_TOPIC} 收发核对]  (按 sha1 精确配对，窗口取客户端实际在听的区间)")
    rx_cb = [r for r in rx if r["topic"] == CB_TOPIC]
    rx_sha = {r["sha1"] for r in rx_cb}
    sent_sha_all = {s["sha1"] for s in sent if s.get("sha1")}

    # 窗口起点取"客户端订阅 CustomByteBlock 生效"那一刻，而不是首包时刻。
    # 否则订阅生效前 broker 照发的那几条会被算成"丢失"，
    # 在健康链路上凭空造出零点几个百分点的假丢包（曾把 0 报成 0.271%）。
    t_cb_sub = next((e["t_ms"] for e in subs
                     if CB_TOPIC in e.get("topics", [])), None)
    win_start = max(t_first, t_cb_sub) if t_cb_sub else t_first

    # fate=drop 是我们主动丢的，要计入"本该到达"；
    # fate=blackhole/freeze 是故障期主动停发，属于中断（用空档时长衡量），
    # 不能混进丢失率，否则断连的锅会被算成丢包。
    all_cb = [s for s in sent if s["topic"] == CB_TOPIC
              and win_start <= s["t_ms"] <= t_last]
    injected = [s for s in all_cb if s.get("fate") == "drop"]
    outage = [s for s in all_cb if s.get("fate") in ("blackhole", "freeze")]
    sent_cb = [s for s in all_cb if s.get("fate", "send") in ("send", "dup")]
    matched = [s for s in sent_cb if s.get("sha1") in rx_sha]
    orphans = [r for r in rx_cb if r["sha1"] not in sent_sha_all]

    # 对外报的是**端到端可见丢失率**：本该拿到多少、实际拿到多少。
    # 若只算"发出去之后又丢的"，等于把注入丢掉的那部分排除在分母外——
    # 注入 5% 却报 0.8%，是自欺欺人。
    should_have = len(sent_cb) + len(injected)
    lost = should_have - len(matched)
    loss_e2e = lost / should_have if should_have else 0.0

    print(f"  应向客户端投递     {should_have} 条（目标 50 Hz）")
    if injected:
        print(f"    其中注入丢弃     {len(injected)} 条 "
              f"({len(injected) / should_have * 100:.2f}%)")
    if outage:
        print(f"  故障期主动停发     {len(outage)} 条（计入中断时长，不计入丢失）")
    print(f"  精确配对成功       {len(matched)} 条")
    print(f"  端到端丢失         {lost} 条  → 丢失率 {loss_e2e * 100:.3f}%")
    report["cb_sent_in_window"] = should_have
    report["cb_injected_drop"] = len(injected)
    report["cb_outage_skipped"] = len(outage)
    report["cb_matched"] = len(matched)
    report["cb_lost"] = lost
    report["cb_loss_rate"] = round(loss_e2e, 6)
    report["cb_loss_rate_effective"] = round(loss_e2e, 6)
    report["cb_orphans"] = len(orphans)
    if orphans:
        print(f"  ⚠ 收到但发送记录里没有 {len(orphans)} 条（不该发生，需排查）")

    # --- 重复与乱序（注入 dup/reorder 后才有意义）---
    seen, dups = set(), 0
    for r in sorted(rx_cb, key=lambda x: x["received_ms"]):
        if r["sha1"] in seen:
            dups += 1
        else:
            seen.add(r["sha1"])
    sent_index = {}
    for i, s in enumerate(sent_cb):
        sent_index.setdefault(s.get("sha1"), i)
    last_idx, reorder = -1, 0
    for r in sorted(rx_cb, key=lambda x: x["received_ms"]):
        idx = sent_index.get(r["sha1"])
        if idx is None:
            continue
        if idx < last_idx:
            reorder += 1
        last_idx = max(last_idx, idx)
    print(f"  重复投递（QoS1 副本） {dups} 条"
          + (f"  → 重复率 {dups / len(rx_cb) * 100:.3f}%" if rx_cb else ""))
    print(f"  乱序到达              {reorder} 条"
          + (f"  → 乱序率 {reorder / len(rx_cb) * 100:.3f}%" if rx_cb else ""))
    report["cb_duplicates"] = dups
    report["cb_dup_rate"] = round(dups / len(rx_cb), 6) if rx_cb else None
    report["cb_reordered"] = reorder
    report["cb_reorder_rate"] = round(reorder / len(rx_cb), 6) if rx_cb else None

    # --- 按客户端已知的去重规则，推算真正进入 GameData 的更新率 ---
    # NetworkManager::parseCustomByteBlock：delta==0（重复）丢弃，delta>127（乱序旧包）丢弃。
    # 关键：乱序在"接收层"看不出损失（RX_TIMING 已经记了），却在"应用层"被静默丢掉。
    # 这是延迟抖动最隐蔽的代价——链路一条没丢，UI 却更新得少了。
    # 规则是确定的，所以可以照着重放一遍把它算出来，不需要改后端。
    seq_by_sha = {s.get("sha1"): s.get("seq")
                  for s in all_cb if s.get("seq") is not None}
    last_seq, n_acc = None, 0
    for r in sorted(rx_cb, key=lambda x: x["received_ms"]):
        q = seq_by_sha.get(r["sha1"])
        if q is None:
            continue
        if last_seq is None:
            last_seq, n_acc = q, 1
            continue
        delta = (q - last_seq) & 0xFF
        if delta == 0 or delta > 127:
            continue                    # 客户端就是在这里 return 的
        last_seq = q
        n_acc += 1
    if rx_cb and span_s:
        eff_hz = n_acc / span_s
        print(f"  推算进入 GameData   {n_acc} 条 → {eff_hz:.2f} Hz"
              f"  (接收 {len(rx_cb)} 条，被去重规则丢掉 {len(rx_cb) - n_acc} 条)")
        report["cb_accepted_est"] = n_acc
        report["cb_effective_hz"] = round(eff_hz, 2)

    # --- 故障事件 ---
    fev = [e for e in events if e["event"].startswith("fault")
           or e["event"] in ("reset_fired", "disconnect", "connect")]
    if any(e["event"] == "fault_start" for e in fev):
        print(f"\n[注入的故障]")
        for e in events:
            if e["event"] == "fault_start":
                print(f"  {e['at_rel_s']:>7.1f}s  {e['action']:<10} 持续 {e['duration_s']}s")
        n_conn = sum(1 for e in events if e["event"] == "connect")
        n_reset = sum(1 for e in events if e["event"] == "reset_fired")
        print(f"  客户端连接次数 {n_conn}（>1 表示发生过重连）；强制 RST {n_reset} 次")
        report["reconnects"] = n_conn - 1
        report["resets"] = n_reset
    report["cb_sent_in_window"] = len(sent_cb)
    report["cb_matched"] = len(matched)
    report["cb_lost"] = lost
    report["cb_loss_rate"] = round(lost / len(sent_cb), 6) if sent_cb else None
    report["cb_orphans"] = len(orphans)

    accepted = [p for p in parsed]
    if accepted:
        accepted_seqs = [p["seq"] for p in accepted]
        print(f"  通过 seq 去重      {len(accepted_seqs)} 条")
        dropped = len(rx_cb) - len(accepted_seqs)
        print(f"  被去重/乱序丢弃    {max(0, dropped)} 条")
        report["cb_received"] = len(rx_cb)
        report["cb_accepted"] = len(accepted_seqs)
        report["cb_dropped_by_dedup"] = max(0, dropped)
    else:
        print("  ⚠ 日志里没有 'Parsed custom data' 行 —— qDebug 在 Release 构建里被裁掉了，")
        print("     所以「通过去重的条数」无法从日志反推。")
        print("     这不影响丢包率（已由 sha1 配对给出）与到达间隔。")
        report["cb_received"] = len(rx_cb)

    # 排队延迟 Q：解析时刻 − 本机接收时刻（按 seq 对齐）
    if accepted:
        # 按接收顺序取 RX 序列，与 accepted 顺序对齐会错位（丢包时），
        # 所以改用"相邻差值"的稳健估计：Q = 解析时刻 − 该包在 RX 序列中的接收时刻。
        # 用 seq 与 sha1 无法直接相连，这里用顺序配对：第 k 个被接受的包，
        # 对应 RX 序列里第 k 个"未被去重丢弃"的包 —— 无丢包时两者一一对应。
        if len(rx_cb) == len(accepted):
            qs = sorted(a["log_ms"] - r["received_ms"]
                        for a, r in zip(accepted, rx_cb)
                        if a["log_ms"] and r["received_ms"])
            if qs:
                report["queue_q_p50_ms"] = pct(qs, 0.50)
                report["queue_q_p95_ms"] = pct(qs, 0.95)
                report["queue_q_p99_ms"] = pct(qs, 0.99)
                report["queue_q_max_ms"] = qs[-1]
                print(f"\n[解析侧排队延迟 Q]  (解析日志时刻 − 本机收到时刻)")
                print(f"  p50 {report['queue_q_p50_ms']} ms   "
                      f"p95 {report['queue_q_p95_ms']} ms   "
                      f"p99 {report['queue_q_p99_ms']} ms   max {qs[-1]} ms")
        else:
            print(f"\n[解析侧排队延迟 Q]  收发条数不等（{len(rx_cb)} vs {len(accepted)}），"
                  f"无法一一配对，跳过")

    # ---------------- 可用率 ----------------
    if len(rx_cb) > 2:
        arr = sorted(r["received_ms"] for r in rx_cb)
        gaps = [b - a for a, b in zip(arr, arr[1:])]
        bad = sum(g for g in gaps if g > 300)
        avail = 1.0 - bad / (arr[-1] - arr[0]) if arr[-1] > arr[0] else 0.0
        report["availability_300ms"] = round(avail, 5)
        report["gap_gt_300ms_count"] = sum(1 for g in gaps if g > 300)
        report["gap_gt_50ms_count"] = sum(1 for g in gaps if g > 50)
        print(f"\n[数据可用率]  以 300 ms 为陈旧阈值：{avail * 100:.3f}%"
              f"  (超过 300ms 的空档 {report['gap_gt_300ms_count']} 次)")
        print(f"  间隔 >50ms 的空档 {report['gap_gt_50ms_count']} 次"
              f" / 共 {len(gaps)} 个间隔")
        # 抖动主要在尾巴上，把最大的几个空档及其发生位置点出来
        report["outage_total_ms"] = bad
        # 恶劣场景下真正要看的不是平均值，而是"最长瞎了多久"
        worst = sorted(((g, a - arr[0]) for g, a in zip(gaps, arr[1:])), reverse=True)[:5]
        big = [(g, off) for g, off in worst if g > 300]
        if big:
            print(f"\n[最长数据中断]  (直接决定 UI 会灰多久)")
            for g, off in big:
                print(f"    {g / 1000:>7.2f} s   起于窗口内 {off / 1000:>6.1f}s")
            report["worst_gap_ms"] = big[0][0]
            report["worst_gaps"] = [{"gap_ms": g, "at_s": round(o / 1000, 2)}
                                    for g, o in big]
        else:
            report["worst_gap_ms"] = max(gaps) if gaps else 0

    out = os.path.join(args.out_dir, "metrics.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"\n指标已写入 {out}")


if __name__ == "__main__":
    main()
