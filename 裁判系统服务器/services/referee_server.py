from __future__ import annotations

import argparse
import json
import struct
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import serial
from serial.tools import list_ports


SOF = 0xA5
DJI_VID = 0x2CA3
DJI_PID = 0x1020
MAX_PAYLOAD = 1024


def crc8(data: bytes, initial: int = 0xFF) -> int:
    value = initial
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ 0x8C if value & 1 else value >> 1
    return value & 0xFF


def crc16(data: bytes, initial: int = 0xFFFF) -> int:
    value = initial
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ 0x8408 if value & 1 else value >> 1
    return value & 0xFFFF


@dataclass
class ParsedFrame:
    command_id: int
    sequence: int
    payload: bytes
    received_at: float = field(default_factory=time.time)


class RefereeFrameParser:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.valid_frames = 0
        self.bad_crc8 = 0
        self.bad_crc16 = 0
        self.discarded_bytes = 0

    def feed(self, data: bytes) -> list[ParsedFrame]:
        self.buffer.extend(data)
        frames: list[ParsedFrame] = []
        while True:
            sof_at = self.buffer.find(SOF)
            if sof_at < 0:
                self.discarded_bytes += len(self.buffer)
                self.buffer.clear()
                break
            if sof_at:
                self.discarded_bytes += sof_at
                del self.buffer[:sof_at]
            if len(self.buffer) < 5:
                break
            if crc8(self.buffer[:4]) != self.buffer[4]:
                self.bad_crc8 += 1
                self.discarded_bytes += 1
                del self.buffer[0]
                continue
            payload_length = int.from_bytes(self.buffer[1:3], "little")
            if payload_length > MAX_PAYLOAD:
                self.discarded_bytes += 1
                del self.buffer[0]
                continue
            frame_length = 9 + payload_length
            if len(self.buffer) < frame_length:
                break
            raw = bytes(self.buffer[:frame_length])
            expected_crc = int.from_bytes(raw[-2:], "little")
            if crc16(raw[:-2]) != expected_crc:
                self.bad_crc16 += 1
                self.discarded_bytes += 1
                del self.buffer[0]
                continue
            command_id = int.from_bytes(raw[5:7], "little")
            frames.append(ParsedFrame(command_id, raw[3], raw[7:-2]))
            self.valid_frames += 1
            del self.buffer[:frame_length]
        return frames


HP_NAMES = (
    "red_hero", "red_engineer", "red_infantry_3", "red_infantry_4",
    "red_infantry_5", "red_sentry", "red_outpost", "red_base",
    "blue_hero", "blue_engineer", "blue_infantry_3", "blue_infantry_4",
    "blue_infantry_5", "blue_sentry", "blue_outpost", "blue_base",
)


GAME_PROGRESS = {
    0: "未开始", 1: "准备", 2: "十五秒裁判系统自检", 3: "五秒倒计时",
    4: "比赛中", 5: "比赛结算",
}


def decode_frame(frame: ParsedFrame) -> dict[str, Any]:
    payload = frame.payload
    decoded: dict[str, Any] = {
        "command_id": f"0x{frame.command_id:04X}",
        "sequence": frame.sequence,
        "payload_length": len(payload),
        "received_at": datetime.fromtimestamp(frame.received_at).isoformat(timespec="milliseconds"),
    }
    try:
        if frame.command_id == 0x0001 and len(payload) >= 3:
            status, remain = struct.unpack_from("<BH", payload)
            decoded.update(
                type="game_status",
                game_type=status & 0x0F,
                game_progress=(status >> 4) & 0x0F,
                game_progress_text=GAME_PROGRESS.get((status >> 4) & 0x0F, "未知"),
                stage_remaining_seconds=remain,
            )
            if len(payload) >= 11:
                decoded["sync_timestamp"] = struct.unpack_from("<Q", payload, 3)[0]
        elif frame.command_id == 0x0002 and payload:
            decoded.update(type="game_result", winner=payload[0])
        elif frame.command_id == 0x0003 and len(payload) >= 2:
            values = struct.unpack_from(f"<{len(payload) // 2}H", payload)
            decoded.update(type="field_hp", hp=dict(zip(HP_NAMES, values)))
        elif frame.command_id == 0x0201 and len(payload) >= 6:
            robot_id, level, current_hp, maximum_hp = struct.unpack_from("<BBHH", payload)
            decoded.update(
                type="robot_status",
                robot_id=robot_id,
                robot_level=level,
                current_hp=current_hp,
                maximum_hp=maximum_hp,
            )
            if len(payload) >= 8:
                decoded["shooter_cooling_rate"] = struct.unpack_from("<H", payload, 6)[0]
        elif frame.command_id == 0x0202 and len(payload) >= 10:
            voltage, current, power, buffer_energy = struct.unpack_from("<HHfH", payload)
            decoded.update(
                type="power_heat",
                chassis_voltage_v=voltage / 1000,
                chassis_current_a=current / 1000,
                chassis_power_w=round(power, 3),
                buffer_energy_j=buffer_energy,
            )
        elif frame.command_id == 0x0208 and len(payload) >= 2:
            values = struct.unpack_from(f"<{len(payload) // 2}H", payload)
            decoded.update(type="projectile_allowance", projectile_17mm=values[0])
            if len(values) > 1:
                decoded["projectile_42mm"] = values[1]
            if len(values) > 2:
                decoded["coins"] = values[2]
        else:
            decoded.update(type="unknown", payload_hex=payload.hex(" "))
    except struct.error as error:
        decoded.update(type="decode_error", error=str(error), payload_hex=payload.hex(" "))
    return decoded


@dataclass
class PortStatus:
    port: str
    description: str
    hardware_id: str
    classification: str
    connected: bool = False
    bytes_received: int = 0
    bytes_per_second: int = 0
    valid_referee_frames: int = 0
    bad_crc8: int = 0
    bad_crc16: int = 0
    discarded_bytes: int = 0
    last_data_at: str | None = None
    last_error: str | None = None
    raw_preview: str = ""


class SharedState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.ports: dict[str, PortStatus] = {}
        self.latest: dict[str, dict[str, Any]] = {}
        self.recent: deque[dict[str, Any]] = deque(maxlen=100)

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "server": {
                    "status": "running",
                    "started_at": datetime.fromtimestamp(self.started_at).isoformat(timespec="seconds"),
                    "uptime_seconds": round(time.time() - self.started_at, 1),
                },
                "ports": [asdict(status) for status in self.ports.values()],
                "latest": self.latest.copy(),
                "recent_frames": list(self.recent)[-20:],
            }


def available_ports() -> list[Any]:
    return sorted(list_ports.comports(), key=lambda port: port.device)


def selected_ports(requested: list[str]) -> list[Any]:
    ports = available_ports()
    if not requested or requested == ["auto"]:
        usb_ports = [port for port in ports if "USB" in (port.hwid or "").upper()]
        return usb_ports or ports
    names = {name.upper() for name in requested}
    return [port for port in ports if port.device.upper() in names]


class SerialReader(threading.Thread):
    def __init__(self, state: SharedState, port_info: Any, baud: int) -> None:
        super().__init__(name=f"serial-{port_info.device}", daemon=True)
        self.state = state
        self.port_info = port_info
        self.baud = baud
        self.stop_event = threading.Event()

    def run(self) -> None:
        parser = RefereeFrameParser()
        device = self.port_info.device
        classification = (
            "DJI 图传私有 USB 通道（硬件诊断，非公开裁判协议）"
            if self.port_info.vid == DJI_VID and self.port_info.pid == DJI_PID
            else "候选裁判串口"
        )
        status = PortStatus(
            port=device,
            description=self.port_info.description or "",
            hardware_id=self.port_info.hwid or "",
            classification=classification,
        )
        with self.state.lock:
            self.state.ports[device] = status
        while not self.stop_event.is_set():
            try:
                with serial.Serial(device, self.baud, timeout=0.2) as stream:
                    with self.state.lock:
                        status.connected = True
                        status.last_error = None
                    rate_started = time.monotonic()
                    rate_bytes = 0
                    while not self.stop_event.is_set():
                        chunk = stream.read(max(stream.in_waiting, 1))
                        if not chunk:
                            continue
                        now = time.time()
                        rate_bytes += len(chunk)
                        frames = parser.feed(chunk)
                        with self.state.lock:
                            status.bytes_received += len(chunk)
                            status.last_data_at = datetime.fromtimestamp(now).isoformat(timespec="milliseconds")
                            status.raw_preview = chunk[-64:].hex(" ")
                            status.valid_referee_frames = parser.valid_frames
                            status.bad_crc8 = parser.bad_crc8
                            status.bad_crc16 = parser.bad_crc16
                            status.discarded_bytes = parser.discarded_bytes
                            if time.monotonic() - rate_started >= 1:
                                status.bytes_per_second = rate_bytes
                                rate_bytes = 0
                                rate_started = time.monotonic()
                            for frame in frames:
                                decoded = decode_frame(frame)
                                self.state.latest[decoded["command_id"]] = decoded
                                self.state.recent.append(decoded)
            except (serial.SerialException, OSError) as error:
                with self.state.lock:
                    status.connected = False
                    status.last_error = str(error)
                self.stop_event.wait(2)


class ApiHandler(BaseHTTPRequestHandler):
    state: SharedState
    index_path: Path

    def do_GET(self) -> None:
        if self.path in ("/api/state", "/health"):
            body = json.dumps(self.state.snapshot(), ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
        elif self.path in ("/", "/index.html"):
            body = self.index_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        else:
            body = b'{"error":"not found"}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, pattern: str, *args: Any) -> None:
        return


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="RoboMaster 裁判系统本地接收服务")
    parser.add_argument("--port", action="append", default=[], help="串口，如 COM5；可重复。默认 auto")
    parser.add_argument("--baud", type=int, default=115200, help="公开裁判串口协议默认 115200")
    parser.add_argument("--host", default="127.0.0.1", help="HTTP 监听地址")
    parser.add_argument("--http-port", type=int, default=8765, help="HTTP 端口")
    parser.add_argument("--list-ports", action="store_true", help="列出串口后退出")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    ports = available_ports()
    if args.list_ports:
        for port in ports:
            print(f"{port.device}: {port.description} [{port.hwid}]")
        return

    state = SharedState()
    readers = [SerialReader(state, port, args.baud) for port in selected_ports(args.port)]
    for reader in readers:
        reader.start()

    ApiHandler.state = state
    ApiHandler.index_path = Path(__file__).with_name("index.html")
    server = ThreadingHTTPServer((args.host, args.http_port), ApiHandler)
    port_names = ", ".join(reader.port_info.device for reader in readers) or "无"
    print(f"裁判系统本地服务: http://{args.host}:{args.http_port}")
    print(f"监听串口: {port_names} @ {args.baud}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        for reader in readers:
            reader.stop_event.set()
        for reader in readers:
            reader.join(timeout=2)


if __name__ == "__main__":
    main()
