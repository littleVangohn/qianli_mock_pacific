#!/usr/bin/env python3
"""电控 E1-E3（11 字节 CustomByteBlock）注入与解码工具。

用法：
  python3 custom_status_tool.py sim   --broker 127.0.0.1 --port 13333 --rate 20 ...
  python3 custom_status_tool.py watch --broker 127.0.0.1 --port 13333 --duration 30

协议以 docs/real_vehicle_integration/电控组最小数据对接文档.md 为准：
  Byte 0      magic 0x5A
  Byte 1      version 0x01
  Byte 2      机构/有效位
  Byte 3      底盘模式 + 警告
  Byte 4-5    gimbal_offset_yaw (int16 LE, 0.0001 rad)
  Byte 6-7    gimbal_yaw        (int16 LE, 0.0001 rad)
  Byte 8-9    barrel_pitch      (int16 LE, 0.0001 rad)
  Byte 10     seq

MQTT topic CustomByteBlock，payload = protobuf 外壳 { bytes data = 1 }，
即 0x0A + varint(len) + data。

依赖：paho-mqtt（WSL 已装 2.1.0）。没有 paho 时只提示，不自动安装。
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:  # pragma: no cover - 运行环境提示
    mqtt = None

MAGIC = 0x5A
VERSION = 1
TOPIC = "CustomByteBlock"
RAD_TO_DEG = 180.0 / math.pi

# Byte 2 位定义
BIT_FRIC = 0
BIT_RAMMER = 1
BIT_FIRE = 2
BIT_AUTOLOB = 3
BIT_EFAULT = 4
BIT_POSE_VALID = 5
BIT_PITCH_VALID = 6


# ---------------------------------------------------------------------------
# 编解码
# ---------------------------------------------------------------------------
def deg_to_i16(deg: float) -> int:
    raw = int(round(float(deg) * math.pi / 180.0 * 10000.0))
    return max(-32768, min(32767, raw))


def i16_to_deg(raw: int) -> float:
    return raw / 10000.0 * RAD_TO_DEG


def encode_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        part = value & 0x7F
        value >>= 7
        if value:
            out.append(part | 0x80)
        else:
            out.append(part)
            return bytes(out)


def decode_varint(buf: bytes, pos: int):
    value = 0
    mult = 1
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        value += (b & 0x7F) * mult
        if not (b & 0x80):
            return value, pos
        mult *= 128
        if mult > 128 ** 4:
            break
    return None, pos


def encode_block(
    *,
    offset_deg: float,
    yaw_deg: float,
    pitch_deg: float,
    mode: int,
    warning: bool,
    fric: bool,
    rammer: bool,
    fire: bool,
    autolob: bool,
    efault: bool,
    pose_valid: bool,
    pitch_valid: bool,
    version: int,
    seq: int,
    pad_bytes: int,
) -> bytes:
    byte2 = 0
    byte2 |= (1 if fric else 0) << BIT_FRIC
    byte2 |= (1 if rammer else 0) << BIT_RAMMER
    byte2 |= (1 if fire else 0) << BIT_FIRE
    byte2 |= (1 if autolob else 0) << BIT_AUTOLOB
    byte2 |= (1 if efault else 0) << BIT_EFAULT
    byte2 |= (1 if pose_valid else 0) << BIT_POSE_VALID
    byte2 |= (1 if pitch_valid else 0) << BIT_PITCH_VALID

    byte3 = (int(mode) & 0x07) | (0x08 if warning else 0)

    block = struct.pack(
        "<BBBBhhhB",
        MAGIC,
        int(version) & 0xFF,
        byte2,
        byte3,
        deg_to_i16(offset_deg),
        deg_to_i16(yaw_deg),
        deg_to_i16(pitch_deg),
        int(seq) & 0xFF,
    )
    if pad_bytes > len(block):
        block += b"\x00" * (pad_bytes - len(block))
    return block


def wrap_protobuf(data: bytes) -> bytes:
    # CustomByteBlock { bytes data = 1; } -> field 1, wire type 2
    return b"\x0a" + encode_varint(len(data)) + data


def unwrap_protobuf(payload: bytes):
    """返回 (data, 说明)。解析失败时 data=None。"""
    if not payload:
        return None, "empty"
    if payload[0] != 0x0A:
        return None, "not field-1 bytes"
    length, pos = decode_varint(payload, 1)
    if length is None:
        return None, "bad varint"
    if pos + length > len(payload):
        return None, f"truncated (want {length}, have {len(payload) - pos})"
    return payload[pos:pos + length], ""


def decode_block(data: bytes) -> dict:
    if len(data) < 11:
        return {"ok": False, "reason": f"too short ({len(data)} < 11)", "raw": data.hex()}
    if data[0] != MAGIC:
        return {"ok": False, "reason": f"bad magic 0x{data[0]:02X}", "raw": data.hex()}

    version = data[1]
    b2 = data[2]
    b3 = data[3]
    offset_raw, yaw_raw, pitch_raw, seq = struct.unpack_from("<hhhB", data, 4)
    return {
        "ok": True,
        "version": version,
        "seq": seq,
        "offset_deg": i16_to_deg(offset_raw),
        "yaw_deg": i16_to_deg(yaw_raw),
        "pitch_deg": i16_to_deg(pitch_raw),
        "mode": b3 & 0x07,
        "warning": bool(b3 & 0x08),
        "fric": bool(b2 & (1 << BIT_FRIC)),
        "rammer": bool(b2 & (1 << BIT_RAMMER)),
        "fire": bool(b2 & (1 << BIT_FIRE)),
        "autolob": bool(b2 & (1 << BIT_AUTOLOB)),
        "efault": bool(b2 & (1 << BIT_EFAULT)),
        "pose_valid": bool(b2 & (1 << BIT_POSE_VALID)),
        "pitch_valid": bool(b2 & (1 << BIT_PITCH_VALID)),
        "len": len(data),
        "raw": data.hex(),
    }


def fmt_flags(d: dict) -> str:
    names = [
        ("fric", "fric"), ("rammer", "rammer"), ("fire", "fire"),
        ("autolob", "autolob"), ("efault", "FAULT"),
        ("pose_valid", "pose"), ("pitch_valid", "pitch"),
    ]
    return " ".join(f"{label}={1 if d[key] else 0}" for key, label in names)


# ---------------------------------------------------------------------------
# sim
# ---------------------------------------------------------------------------
def make_client(client_id: str):
    if mqtt is None:
        print("缺少 paho-mqtt：请在 WSL 里 pip install paho-mqtt（本机已有 2.1.0）",
              file=sys.stderr)
        raise SystemExit(2)
    return mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)


def cmd_sim(args) -> int:
    if args.rate <= 0:
        print("--rate 必须大于 0", file=sys.stderr)
        return 2
    if args.pad_bytes < 11:
        print("--pad-bytes 至少 11", file=sys.stderr)
        return 2

    client = make_client(args.client_id)

    def on_connect(c, userdata, flags, reason_code, properties):
        print(f"[sim] connect {args.broker}:{args.port} -> {reason_code}", flush=True)

    def on_disconnect(c, userdata, flags, reason_code, properties):
        print(f"[sim] disconnect -> {reason_code}", flush=True)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    try:
        client.connect(args.broker, args.port, keepalive=30)
    except Exception as exc:
        print(f"[sim] 连接失败: {exc}", file=sys.stderr)
        return 1
    client.loop_start()

    period = 1.0 / args.rate
    start = time.monotonic()
    next_t = start
    seq = args.seq_start & 0xFF
    sent = 0
    last_report = start

    print(f"[sim] {args.rate:g} Hz, version={args.version}, "
          f"offset={args.offset_deg:g} yaw={args.yaw_deg:g} pitch={args.pitch_deg:g} "
          f"mode={args.mode} warning={int(args.warning)} "
          f"pad={args.pad_bytes} qos={args.qos}", flush=True)

    try:
        while True:
            now = time.monotonic()
            if args.duration > 0 and now - start >= args.duration:
                break
            if now < next_t:
                time.sleep(min(next_t - now, 0.05))
                continue

            t = now - start
            offset = args.offset_deg
            pitch = args.pitch_deg
            if args.sweep:
                phase = 2.0 * math.pi * t / max(0.1, args.sweep_period)
                offset = args.sweep_offset_amp * math.sin(phase)
                pitch = 17.5 + 27.5 * math.sin(phase + math.pi / 3.0)

            block = encode_block(
                offset_deg=offset,
                yaw_deg=args.yaw_deg,
                pitch_deg=pitch,
                mode=args.mode,
                warning=args.warning,
                fric=args.fric,
                rammer=args.rammer,
                fire=args.fire,
                autolob=args.autolob,
                efault=args.efault,
                pose_valid=args.pose_valid,
                pitch_valid=args.pitch_valid,
                version=args.version,
                seq=seq,
                pad_bytes=args.pad_bytes,
            )
            payload = wrap_protobuf(block)
            client.publish(TOPIC, payload, qos=args.qos)
            sent += 1

            if args.verbose:
                d = decode_block(block)
                print(f"[sim] seq={d['seq']:3d} offset={d['offset_deg']:+7.1f} "
                      f"yaw={d['yaw_deg']:+7.1f} pitch={d['pitch_deg']:+6.1f} "
                      f"mode={d['mode']} {fmt_flags(d)} len={d['len']} "
                      f"hex={d['raw']}", flush=True)
            elif now - last_report >= 1.0:
                d = decode_block(block)
                print(f"[sim] t={t:5.1f}s seq={d['seq']:3d} "
                      f"offset={d['offset_deg']:+7.1f} pitch={d['pitch_deg']:+6.1f} "
                      f"mode={d['mode']} sent={sent}", flush=True)
                last_report = now

            if args.duplicate:
                client.publish(TOPIC, payload, qos=args.qos)

            if not args.hold_seq:
                seq = (seq + args.seq_step) & 0xFF

            next_t += period
            if next_t < now - period:
                next_t = now + period
    except KeyboardInterrupt:
        print("\n[sim] stopped", flush=True)
    finally:
        client.loop_stop()
        client.disconnect()

    print(f"[sim] 共发送 {sent} 个状态包", flush=True)
    return 0


# ---------------------------------------------------------------------------
# watch
# ---------------------------------------------------------------------------
def cmd_watch(args) -> int:
    counts = {"packets": 0, "new": 0, "dup": 0, "old": 0, "gap_packets": 0,
              "timeouts": 0, "bad": 0, "not_status": 0}
    last_seq = None
    last_new_t = None
    timeout_reported = False
    start = time.monotonic()

    client = make_client(args.client_id)
    client.user_data_set(counts)

    def on_connect(c, userdata, flags, reason_code, properties):
        print(f"[watch] connect {args.broker}:{args.port} -> {reason_code}", flush=True)
        c.subscribe(args.topic, qos=1)

    def on_message(c, userdata, msg):
        nonlocal last_seq, last_new_t, timeout_reported
        counts["packets"] += 1
        data, why = unwrap_protobuf(msg.payload)
        if data is None:
            counts["bad"] += 1
            print(f"[watch] BAD wrapper ({why}) payload={msg.payload.hex()}", flush=True)
            return
        d = decode_block(data)
        if not d["ok"]:
            counts["not_status"] += 1
            print(f"[watch] not status: {d['reason']} data={d['raw']}", flush=True)
            return
        if args.raw:
            print(f"[watch] raw {d['raw']}", flush=True)

        now = time.monotonic()
        seq = d["seq"]
        if last_seq is None:
            last_seq = seq
            last_new_t = now
            counts["new"] += 1
            print(f"[watch] seq={seq:3d} len={d['len']} v={d['version']} "
                  f"offset={d['offset_deg']:+7.1f} yaw={d['yaw_deg']:+7.1f} "
                  f"pitch={d['pitch_deg']:+6.1f} mode={d['mode']} "
                  f"warn={int(d['warning'])} {fmt_flags(d)}", flush=True)
            return

        delta = (seq - last_seq) & 0xFF
        if delta == 0:
            counts["dup"] += 1
            print(f"[watch] DUP seq={seq}", flush=True)
            return
        if delta > 127:
            counts["old"] += 1
            print(f"[watch] OLD seq={seq} (last={last_seq}, delta={delta})", flush=True)
            return

        if timeout_reported:
            print(f"[watch] RECOVER seq={seq} after timeout", flush=True)
            timeout_reported = False
        if delta > 1:
            counts["gap_packets"] += delta - 1
            print(f"[watch] GAP {delta - 1} packet(s) before seq={seq}", flush=True)
        age = 0 if last_new_t is None else int((now - last_new_t) * 1000)
        last_seq = seq
        last_new_t = now
        counts["new"] += 1
        print(f"[watch] seq={seq:3d} len={d['len']} v={d['version']} "
              f"offset={d['offset_deg']:+7.1f} yaw={d['yaw_deg']:+7.1f} "
              f"pitch={d['pitch_deg']:+6.1f} mode={d['mode']} "
              f"warn={int(d['warning'])} {fmt_flags(d)} age={age}ms", flush=True)

    client.on_connect = on_connect
    client.on_message = on_message
    try:
        client.connect(args.broker, args.port, keepalive=30)
    except Exception as exc:
        print(f"[watch] 连接失败: {exc}", file=sys.stderr)
        return 1

    print(f"[watch] 订阅 {args.topic} @ {args.broker}:{args.port}", flush=True)
    try:
        while True:
            rc = client.loop(timeout=0.05)
            if rc != mqtt.MQTT_ERR_SUCCESS:
                print(f"[watch] loop rc={rc}", file=sys.stderr)
                break
            now = time.monotonic()
            if args.duration > 0 and now - start >= args.duration:
                break
            if last_new_t is not None and not timeout_reported:
                if (now - last_new_t) * 1000.0 > 300.0:
                    timeout_reported = True
                    counts["timeouts"] += 1
                    print(f"[watch] TIMEOUT >300 ms without new seq "
                          f"(last seq={last_seq})", flush=True)
    except KeyboardInterrupt:
        print("\n[watch] stopped", flush=True)
    finally:
        client.disconnect()

    print("[watch] summary: " + " ".join(f"{k}={v}" for k, v in counts.items()),
          flush=True)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="电控 E1-E3 CustomByteBlock 注入/解码")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sim = sub.add_parser("sim", help="20 Hz 注入 11 字节状态包")
    sim.add_argument("--broker", default="127.0.0.1")
    sim.add_argument("--port", type=int, default=3333)
    sim.add_argument("--client-id", default="custom-status-sim")
    sim.add_argument("--rate", type=float, default=20.0)
    sim.add_argument("--duration", type=float, default=0.0, help="0 = 一直发")
    sim.add_argument("--qos", type=int, choices=(0, 1), default=0)
    sim.add_argument("--offset-deg", type=float, default=30.0)
    sim.add_argument("--yaw-deg", type=float, default=45.0)
    sim.add_argument("--pitch-deg", type=float, default=12.3)
    sim.add_argument("--mode", type=int, choices=(0, 1, 2, 3), default=2)
    sim.add_argument("--warning", action=argparse.BooleanOptionalAction, default=False)
    sim.add_argument("--fric", action=argparse.BooleanOptionalAction, default=True)
    sim.add_argument("--rammer", action=argparse.BooleanOptionalAction, default=False)
    sim.add_argument("--fire", action=argparse.BooleanOptionalAction, default=True)
    sim.add_argument("--autolob", action=argparse.BooleanOptionalAction, default=False)
    sim.add_argument("--efault", action=argparse.BooleanOptionalAction, default=False)
    sim.add_argument("--pose-valid", action=argparse.BooleanOptionalAction, default=True)
    sim.add_argument("--pitch-valid", action=argparse.BooleanOptionalAction, default=True)
    sim.add_argument("--version", type=int, default=1)
    sim.add_argument("--seq-start", type=int, default=0)
    sim.add_argument("--seq-step", type=int, default=1,
                     help="负值可模拟乱序旧包；255 回绕自动处理")
    sim.add_argument("--hold-seq", action="store_true",
                     help="seq 不递增，客户端应只认第一包并在 300 ms 后失联")
    sim.add_argument("--duplicate", action="store_true",
                     help="每个包重复发一次（同 seq），测试去重")
    sim.add_argument("--pad-bytes", type=int, default=11,
                     help="把 data 补零到该长度（11/150/300），至少 11")
    sim.add_argument("--sweep", action="store_true", help="左右扫掠 offset 和 pitch")
    sim.add_argument("--sweep-period", type=float, default=6.0)
    sim.add_argument("--sweep-offset-amp", type=float, default=60.0)
    sim.add_argument("--verbose", action="store_true", help="逐包打印")
    sim.set_defaults(func=cmd_sim)

    watch = sub.add_parser("watch", help="订阅并解码 CustomByteBlock")
    watch.add_argument("--broker", default="127.0.0.1")
    watch.add_argument("--port", type=int, default=3333)
    watch.add_argument("--client-id", default="custom-status-watch")
    watch.add_argument("--topic", default=TOPIC)
    watch.add_argument("--duration", type=float, default=0.0, help="0 = 一直看")
    watch.add_argument("--raw", action="store_true", help="额外打印原始 hex")
    watch.set_defaults(func=cmd_watch)

    return ap


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
