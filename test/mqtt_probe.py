#!/usr/bin/env python3
"""最小 MQTT 3.1.1 探针：只发 CONNECT，读 CONNACK 返回码。不依赖任何库。

用来区分两种假设：
  - "同一 ClientId 只能一个连接"  -> 换个 ID 就能进
  - "broker 按来源 IP 白名单"      -> 换任何 ID 都进不去
"""
import socket
import struct
import sys


def mqtt_connect(host, port, client_id, timeout=5.0):
    """返回 (connack_code, 说明)。code=None 表示没收到 CONNACK。"""
    # 可变长度字段：ClientId
    cid = client_id.encode("utf-8")
    payload = struct.pack("!H", len(cid)) + cid

    # 可变头：协议名 "MQTT" + 版本 4 (3.1.1) + 连接标志 + keepalive
    var_header = struct.pack("!H", 4) + b"MQTT" + bytes([4, 0x02, 0x00, 0x3C])
    # 0x02 = clean session

    remaining = var_header + payload
    # remaining length 用可变字节整数编码（这里一定 < 128）
    packet = bytes([0x10, len(remaining)]) + remaining

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        s.sendall(packet)
        resp = s.recv(4)
    except Exception as e:
        return None, f"连接/收发失败: {e}"
    finally:
        s.close()

    if len(resp) < 4:
        return None, f"CONNACK 太短: {resp!r}"
    if resp[0] != 0x20:
        return None, f"不是 CONNACK: {resp!r}"
    return resp[3], ""


CODES = {
    0: "接受 ✅",
    1: "协议版本不支持",
    2: "ClientId 被拒 ❌",
    3: "服务不可用",
    4: "用户名密码错误",
    5: "未授权",
}


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "172.28.48.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3333
    ids = sys.argv[3:] or ["1", "2", "3", "7", "101", "probe-x9"]

    print(f"目标 broker: {host}:{port}")
    print(f"{'ClientId':<14} {'返回码':<8} 说明")
    print("-" * 56)
    for cid in ids:
        code, err = mqtt_connect(host, port, cid)
        if code is None:
            print(f"{cid:<14} {'--':<8} {err}")
        else:
            print(f"{cid:<14} {code:<8} {CODES.get(code, '未知')}")
            sys.stdout.flush()
            import time
            time.sleep(0.3)


if __name__ == "__main__":
    main()
