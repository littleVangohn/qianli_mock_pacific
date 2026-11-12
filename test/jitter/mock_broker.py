#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线 MQTT 3.1.1 broker + 裁判协议数据源 + 故障注入器

为什么自己写 broker：
  * 这台机器没有 docker，也没有 mosquitto
  * 要注入的是"消息级"故障（丢哪一条、延迟多久、重复几次），
    只有掌握投递时刻的一方才做得到；tc netem 只能按字节丢，
    会把 MQTT 帧切坏，测出来的不是"消息丢了"而是"协议错误"

三类故障，各自对应真实赛场的一种恶劣：
  消息级  drop / burst / delay+jitter / duplicate   —— 无线链路丢包与抖动
  会话级  blackhole                                 —— 假死：TCP 还连着，但对端不再应答
  连接级  reset                                     —— 闪断：连接被强制中断

  blackhole 的关键是**同时不答 PINGREQ**：对客户端而言，这与网线被拔无法区分
  （keepAlive 到期发 PINGREQ 收不到 PINGRESP → 判失联）。只停发数据不答心跳
  的话，测的就只是业务层新鲜度，那是另一回事，用 freeze。

不修改仓库里任何既有文件；只 import upstream/sim/robomaster_pb2.py。

用法：
  python3 mock_broker.py --port 13333 --out-dir ./out/x --duration 90 \
      --drop-rate 0.02 --scenario "blackhole@20+10,reset@50"
"""

import argparse
import hashlib
import heapq
import json
import math
import os
import random
import socket
import struct
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))
# 导入 upstream 的模块时不要在那里留下 __pycache__ —— 那个目录要保持原样
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(_REPO, "upstream", "sim"))
import robomaster_pb2 as pb  # noqa: E402


# ============================================================================
# MQTT 3.1.1 报文编解码
# ============================================================================
def encode_remaining_length(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        if n > 0:
            b |= 0x80
        out.append(b)
        if n == 0:
            break
    return bytes(out)


def make_publish(topic: str, payload: bytes, packet_id: int = 0, qos: int = 0) -> bytes:
    vh = struct.pack("!H", len(topic)) + topic.encode("utf-8")
    if qos > 0:
        vh += struct.pack("!H", packet_id)
    body = vh + payload
    return bytes([0x30 | (qos << 1)]) + encode_remaining_length(len(body)) + body


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return bytes(buf)


def read_packet(sock: socket.socket):
    b1 = recv_exact(sock, 1)[0]
    ptype, flags = b1 >> 4, b1 & 0x0F
    mult, length = 1, 0
    while True:
        b = recv_exact(sock, 1)[0]
        length += (b & 0x7F) * mult
        if not (b & 0x80):
            break
        mult *= 128
        if mult > 128 ** 3:
            raise ValueError("malformed remaining length")
    body = recv_exact(sock, length) if length else b""
    return ptype, flags, body


def parse_connect(body: bytes):
    i = 0
    n = struct.unpack_from("!H", body, i)[0]; i += 2
    proto = body[i:i + n].decode("utf-8", "replace"); i += n
    level = body[i]; i += 1
    flags = body[i]; i += 1
    keepalive = struct.unpack_from("!H", body, i)[0]; i += 2
    n = struct.unpack_from("!H", body, i)[0]; i += 2
    client_id = body[i:i + n].decode("utf-8", "replace")
    return proto, level, flags, keepalive, client_id


def parse_subscribe(body: bytes):
    pid = struct.unpack_from("!H", body, 0)[0]
    i, topics = 2, []
    while i < len(body):
        n = struct.unpack_from("!H", body, i)[0]; i += 2
        t = body[i:i + n].decode("utf-8", "replace"); i += n
        q = body[i]; i += 1
        topics.append((t, q))
    return pid, topics


def parse_publish(flags: int, body: bytes):
    qos = (flags >> 1) & 0x03
    i = 0
    n = struct.unpack_from("!H", body, i)[0]; i += 2
    topic = body[i:i + n].decode("utf-8", "replace"); i += n
    pid = 0
    if qos > 0:
        pid = struct.unpack_from("!H", body, i)[0]; i += 2
    return topic, body[i:], qos, pid


# ============================================================================
# 订阅者
# ============================================================================
class Subscriber:
    def __init__(self, conn: socket.socket, addr, client_id: str):
        self.conn = conn
        self.addr = addr
        self.client_id = client_id
        self.topics = set()
        self._send_lock = threading.Lock()
        self._pid = 0
        self.published = 0
        # 客户端主动发来的包数。这是**不依赖客户端日志**的存活探针：
        # 客户端在重连后日志可能失效，但它是否还在发键鼠帧骗不了人。
        self.rx_count = 0
        self.alive = True

    def next_pid(self) -> int:
        self._pid = (self._pid % 65535) + 1
        return self._pid

    def send(self, data: bytes) -> bool:
        with self._send_lock:
            try:
                self.conn.sendall(data)
                return True
            except OSError:
                self.alive = False
                return False

    def reset(self):
        """发真 RST（SO_LINGER=0 时不走四次挥手，直接 RST）。"""
        self.alive = False
        try:
            self.conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                 struct.pack("ii", 1, 0))
            self.conn.close()
        except OSError:
            pass


# ============================================================================
# 数据源
# ============================================================================
def make_status_block(seq: int, t: float) -> bytes:
    b = bytearray(11)
    b[0] = 0x5A
    b[1] = 1
    b[2] = 0b01100001
    b[3] = 2
    struct.pack_into("<h", b, 4, int(math.sin(t * 1.7) * 9000))
    struct.pack_into("<h", b, 6, int(math.sin(t * 0.6) * 18000))
    struct.pack_into("<h", b, 8, int(math.sin(t * 1.1) * 3000))
    b[10] = seq & 0xFF
    return bytes(b)


class DataSource:
    def __init__(self):
        self.seq = 0

    def custom_byte_block(self, t: float) -> bytes:
        block = make_status_block(self.seq, t)
        self.seq = (self.seq + 1) & 0xFF
        m = pb.CustomByteBlock()
        m.data = block
        return m.SerializeToString()

    def game_status(self, t: float) -> bytes:
        m = pb.GameStatus()
        m.current_round = 1
        m.total_rounds = 3
        m.red_score = int(t * 2)
        m.blue_score = int(t * 1.5)
        m.current_stage = 4
        m.stage_elapsed_sec = int(t)
        m.stage_countdown_sec = 0
        m.is_paused = False
        return m.SerializeToString()

    def robot_dynamic(self, t: float) -> bytes:
        m = pb.RobotDynamicStatus()
        m.current_health = 400 - int(t * 3)
        m.current_heat = (t * 7) % 240.0
        m.current_chassis_energy = 60
        m.current_buffer_energy = 50
        m.current_experience = int(t * 10)
        m.experience_for_upgrade = 1000
        m.total_projectiles_fired = int(t * 5)
        m.remaining_ammo = 200
        m.is_out_of_combat = False
        m.out_of_combat_countdown = 0
        return m.SerializeToString()

    def global_unit(self, t: float) -> bytes:
        m = pb.GlobalUnitStatus()
        m.base_health = 5000
        m.base_status = 1
        m.base_shield = 2000
        m.outpost_health = 1500
        m.outpost_status = 1
        m.enemy_base_health = 5000
        m.enemy_base_status = 1
        m.robot_health.extend([400 - int(t * 3), 380, 360, 340])
        m.robot_bullets.extend([200, 180, 160, 140])
        m.total_damage_ally = int(t * 30)
        m.total_damage_enemy = int(t * 25)
        return m.SerializeToString()

    def robot_module(self, t: float) -> bytes:
        m = pb.RobotModuleStatus()
        for f in ("power_manager", "rfid", "light_strip", "small_shooter",
                  "big_shooter", "uwb", "armor", "video_transmission",
                  "capacitor", "main_controller", "laser_detection_module"):
            setattr(m, f, 1)
        return m.SerializeToString()

    def global_logistics(self, t: float) -> bytes:
        m = pb.GlobalLogisticsStatus()
        m.remaining_economy = 300 + int(t * 4)
        m.total_economy_obtained = 300 + int(t * 4)
        m.tech_level = 2
        m.encryption_level = 1
        return m.SerializeToString()


PLAN = [
    ("CustomByteBlock",        50.0, "custom_byte_block"),
    ("GameStatus",              5.0, "game_status"),
    ("RobotDynamicStatus",      5.0, "robot_dynamic"),
    ("GlobalUnitStatus",        2.0, "global_unit"),
    ("RobotModuleStatus",       1.0, "robot_module"),
    ("GlobalLogisticsStatus",   1.0, "global_logistics"),
]


# ============================================================================
# 故障引擎
# ============================================================================
class Faults:
    """
    action@time[+duration]，逗号分隔，时间相对"首个客户端连上"那一刻计。
      blackhole  完全不发也不收（不答 PINGREQ）—— 测假死检测
      freeze     只停发数据，心跳照答      —— 测业务层新鲜度
      reset      强制 RST 断开              —— 测重连与恢复
    例：--scenario "blackhole@20+10,reset@50,freeze@70+8"
    """

    def __init__(self, args, log_event):
        self.drop_rate = args.drop_rate
        self.delay_ms = args.delay_ms
        self.delay_jitter_ms = args.delay_jitter_ms
        self.dup_rate = args.dup_rate
        self.burst_gb = args.burst_gb
        self.burst_bg = args.burst_bg
        self.log_event = log_event
        self.t0 = None
        self.events = self._parse(args.scenario)
        self.fired = set()
        self.blackhole_until = 0.0
        self.freeze_until = 0.0
        self.reset_at = None
        self._in_bad = False

    @staticmethod
    def _parse(spec):
        evs = []
        for part in (spec or "").split(","):
            part = part.strip()
            if not part:
                continue
            action, _, timing = part.partition("@")
            t_s, _, dur_s = timing.partition("+")
            evs.append((float(t_s), action.strip(), float(dur_s or 0)))
        return sorted(evs)

    def arm(self, t_rel):
        if self.t0 is None:
            self.t0 = t_rel

    def tick(self, t_rel):
        """触发到点的场景事件。返回 True 表示本 tick 要求 RST。"""
        if self.t0 is None:
            return False
        rel = t_rel - self.t0
        do_reset = False
        for i, (at, action, dur) in enumerate(self.events):
            if i in self.fired or rel < at:
                continue
            self.fired.add(i)
            self.log_event("fault_start", action=action, at_rel_s=round(rel, 2),
                           duration_s=dur)
            if action == "blackhole":
                self.blackhole_until = t_rel + dur
            elif action == "freeze":
                self.freeze_until = t_rel + dur
            elif action == "reset":
                do_reset = True
            if dur > 0:
                threading.Timer(
                    dur, lambda a=action: self.log_event("fault_end", action=a)
                ).start()
        return do_reset

    def in_blackhole(self, t_rel) -> bool:
        return t_rel < self.blackhole_until

    def in_freeze(self, t_rel) -> bool:
        return t_rel < self.freeze_until

    def classify(self):
        """决定这条消息的命运：send / drop / dup。"""
        if self.burst_gb > 0:
            # 两状态马尔可夫（Gilbert-Elliott）：坏状态成串丢，
            # 这才是无线链路的真实形态，比均匀丢包狠得多。
            if self._in_bad:
                if random.random() < self.burst_bg:
                    self._in_bad = False
            else:
                if random.random() < self.burst_gb:
                    self._in_bad = True
            if self._in_bad:
                return "drop"
        elif self.drop_rate > 0 and random.random() < self.drop_rate:
            return "drop"
        if self.dup_rate > 0 and random.random() < self.dup_rate:
            return "dup"
        return "send"

    def delay_seconds(self):
        if self.delay_ms <= 0 and self.delay_jitter_ms <= 0:
            return 0.0
        d = self.delay_ms + random.uniform(-self.delay_jitter_ms, self.delay_jitter_ms)
        return max(0.0, d) / 1000.0


# ============================================================================
# Broker
# ============================================================================
class Broker:
    def __init__(self, port: int, out_dir: str, args):
        self.port = port
        self.out_dir = out_dir
        self.args = args
        self.subs = []
        self.subs_lock = threading.Lock()
        self.stop = threading.Event()
        self.t0 = None
        self.data = DataSource()
        self.sent_f = open(os.path.join(out_dir, "sent.jsonl"), "w", encoding="utf-8")
        self.ev_f = open(os.path.join(out_dir, "events.jsonl"), "w", encoding="utf-8")
        self._log_lock = threading.Lock()
        self.faults = Faults(args, self.log_event)
        self.pending = []            # (send_at, seqno, Subscriber, bytes)
        self._pending_lock = threading.Lock()
        self._send_seq = 0

    # --- 记录 ---
    def log_sent(self, topic: str, payload: bytes, seq=None, fate="send"):
        rec = {"t_ms": int(time.time() * 1000), "topic": topic,
               "bytes": len(payload), "sha1": hashlib.sha1(payload).hexdigest()}
        if seq is not None:
            rec["seq"] = seq
        if fate != "send":
            rec["fate"] = fate
        with self._log_lock:
            self.sent_f.write(json.dumps(rec) + "\n")

    def forward_publish(self, topic: str, payload: bytes):
        """把某个客户端 PUBLISH 的消息转发给主题匹配的订阅者（精确匹配）。

        只用于联调注入；原生 PLAN 的发布仍走 publish_loop。
        """
        with self.subs_lock:
            targets = [s for s in self.subs if s.alive and topic in s.topics]
        if not targets:
            return
        for s in targets:
            if s.send(make_publish(topic, payload, qos=0)):
                s.published += 1
        self.log_sent(topic, payload, fate="forward")

    def log_event(self, kind: str, **kw):
        rec = {"t_ms": int(time.time() * 1000), "event": kind}
        rec.update(kw)
        with self._log_lock:
            self.ev_f.write(json.dumps(rec) + "\n")
            self.ev_f.flush()

    # --- 客户端处理 ---
    def handle_client(self, conn: socket.socket, addr):
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sub = None
        try:
            # 黑洞期间连握手都不该完成。真网络中断是把包丢掉，
            # 而不是"连得上但没数据"——早先在这里漏了这一条，
            # 测出来的是偏轻的故障。
            while (self.faults.in_blackhole(time.monotonic())
                   and not self.stop.is_set()):
                time.sleep(0.05)
            ptype, flags, body = read_packet(conn)
            if ptype != 1:
                conn.close()
                return
            _, level, _, keepalive, client_id = parse_connect(body)
            # 场景计时以"首个客户端连上"为零点：这样无论 broker 提前多久启动，
            # 故障都落在客户端已经在听的时段里，实验才可复现。
            self.faults.arm(time.monotonic())
            sub = Subscriber(conn, addr, client_id)
            with self.subs_lock:
                self.subs.append(sub)
            self.log_event("connect", client_id=client_id,
                           addr=f"{addr[0]}:{addr[1]}",
                           mqtt_level=level, keepalive=keepalive)
            sub.send(b"\x20\x02\x00\x00")

            while not self.stop.is_set():
                if self.faults.in_blackhole(time.monotonic()):
                    # 假死期间：不读也不答。PINGREQ 收不到 PINGRESP，
                    # 客户端只能靠 keepAlive 超时发现自己掉线。
                    time.sleep(0.05)
                    continue
                conn.settimeout(0.2)
                try:
                    ptype, flags, body = read_packet(conn)
                except socket.timeout:
                    continue
                if ptype == 8:
                    pid, topics = parse_subscribe(body)
                    for t, q in topics:
                        sub.topics.add(t)
                    granted = b"".join(bytes([min(q, 1)]) for _, q in topics)
                    sub.send(bytes([0x90]) + encode_remaining_length(2 + len(granted))
                             + struct.pack("!H", pid) + granted)
                    self.log_event("subscribe", client_id=client_id,
                                   topics=[t for t, _ in topics])
                elif ptype == 3:
                    topic, payload, qos, pid = parse_publish(flags, body)
                    sub.rx_count += 1
                    if qos == 1:
                        sub.send(b"\x40\x02" + struct.pack("!H", pid))
                    # 把外部注入器发来的消息转发给订阅者，这样
                    # custom_status_tool.py sim 可以和客户端同时连这个 broker。
                    self.forward_publish(topic, payload)
                elif ptype == 12:
                    sub.send(b"\xd0\x00")
                elif ptype == 14:
                    break
                elif ptype == 4:
                    pass
        except (ConnectionError, OSError, ValueError, socket.timeout):
            pass
        finally:
            if sub:
                with self.subs_lock:
                    if sub in self.subs:
                        self.subs.remove(sub)
                was_alive = sub.alive
                sub.alive = False
                self.log_event("disconnect", client_id=sub.client_id,
                               published=sub.published, rx_from_client=sub.rx_count,
                               abrupt=not was_alive)
            try:
                conn.close()
            except OSError:
                pass

    # --- 发布 ---
    def publish_loop(self):
        self.t0 = time.monotonic()
        # --no-custom-block：由外部 20 Hz 注入器提供状态包，broker 只转发。
        plan = [entry for entry in PLAN
                if not (self.args.no_custom_block and entry[0] == "CustomByteBlock")]
        nxt = {topic: self.t0 for topic, _, _ in plan}
        periods = {topic: 1.0 / hz for topic, hz, _ in plan}
        getters = {topic: getattr(self.data, fn) for topic, _, fn in plan}
        next_liveness = self.t0 + 5.0

        while not self.stop.is_set():
            now = time.monotonic()

            # 每 5 秒记一次存活快照。客户端重连后日志可能失效，
            # 但它还在不在发键鼠帧，从这边看是确定的。
            if now >= next_liveness:
                next_liveness += 5.0
                with self.subs_lock:
                    snap = [{"id": s.client_id, "rx": s.rx_count, "tx": s.published}
                            for s in self.subs]
                self.log_event("liveness", t_rel_s=round(now - self.t0, 1),
                               clients=snap)

            # RST 要"当时连着谁就踢谁"，且只踢一次。
            # 早先用了个 reset_pending 标志，消费后不清除，
            # 结果客户端每次重连都被立刻再踢掉——重连永远不可能成功。
            if self.faults.tick(now):
                with self.subs_lock:
                    victims = list(self.subs)
                for s in victims:
                    self.log_event("reset_fired", client_id=s.client_id)
                    s.reset()

            blackhole = self.faults.in_blackhole(now)
            freeze = self.faults.in_freeze(now)

            # 到期的延迟消息先发出去
            with self._pending_lock:
                due = []
                while self.pending and self.pending[0][0] <= now:
                    due.append(heapq.heappop(self.pending))
            for _, _, s, pkt in due:
                if s.alive and not blackhole:
                    if s.send(pkt):
                        s.published += 1

            for topic, _, _ in plan:
                if now < nxt[topic]:
                    continue
                nxt[topic] += periods[topic]
                if nxt[topic] < now - 1.0:
                    nxt[topic] = now + periods[topic]

                t_rel = now - self.t0
                seq = self.data.seq if topic == "CustomByteBlock" else None
                payload = getters[topic](t_rel)

                if blackhole:
                    self.log_sent(topic, payload, seq, fate="blackhole")
                    continue
                if freeze and topic == "CustomByteBlock":
                    self.log_sent(topic, payload, seq, fate="freeze")
                    continue

                fate = self.faults.classify()
                self.log_sent(topic, payload, seq, fate=fate)
                if fate == "drop":
                    continue

                with self.subs_lock:
                    targets = [s for s in self.subs if s.alive and topic in s.topics]
                for s in targets:
                    n = 2 if fate == "dup" else 1
                    for _ in range(n):
                        pkt = make_publish(topic, payload, s.next_pid(), qos=1)
                        d = self.faults.delay_seconds()
                        if d > 0:
                            self._send_seq += 1
                            with self._pending_lock:
                                heapq.heappush(self.pending,
                                               (now + d, self._send_seq, s, pkt))
                        elif s.send(pkt):
                            s.published += 1
            time.sleep(0.0008)

    def serve(self, duration: float):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", self.port))
        srv.listen(4)
        srv.settimeout(0.3)
        print(f"[broker] 监听 127.0.0.1:{self.port}", flush=True)
        if self.args.drop_rate or self.args.burst_gb or self.args.delay_ms or \
           self.args.dup_rate or self.args.scenario:
            print(f"[broker] 故障配置: drop={self.args.drop_rate} "
                  f"burst_gb={self.args.burst_gb} delay={self.args.delay_ms}"
                  f"±{self.args.delay_jitter_ms}ms dup={self.args.dup_rate} "
                  f"scenario={self.args.scenario or '-'}", flush=True)

        threading.Thread(target=self.publish_loop, daemon=True).start()

        deadline = time.monotonic() + duration if duration > 0 else None
        try:
            while not self.stop.is_set():
                if deadline and time.monotonic() > deadline:
                    break
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=self.handle_client, args=(conn, addr),
                                 daemon=True).start()
        finally:
            self.stop.set()
            time.sleep(0.25)
            with self._log_lock:
                self.sent_f.close()
                self.ev_f.close()
            print("[broker] 已停止", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=13333)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--drop-rate", type=float, default=0.0, help="均匀丢包概率")
    ap.add_argument("--burst-gb", type=float, default=0.0,
                    help="成串丢包：好→坏 的转移概率（0.01 起步）")
    ap.add_argument("--burst-bg", type=float, default=0.3,
                    help="成串丢包：坏→好 的转移概率（越小串越长）")
    ap.add_argument("--delay-ms", type=float, default=0.0)
    ap.add_argument("--delay-jitter-ms", type=float, default=0.0)
    ap.add_argument("--dup-rate", type=float, default=0.0)
    ap.add_argument("--scenario", default="", help='例 "blackhole@20+10,reset@50"')
    ap.add_argument("--no-custom-block", action="store_true",
                    help="不发布内置 50 Hz CustomByteBlock，由外部注入器提供")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    Broker(args.port, args.out_dir, args).serve(args.duration)


if __name__ == "__main__":
    main()
