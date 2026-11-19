import struct
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parents[1]))
from referee_server import ParsedFrame, RefereeFrameParser, crc8, crc16, decode_frame


def make_frame(command_id: int, payload: bytes, sequence: int = 1) -> bytes:
    header = bytearray((0xA5, len(payload) & 0xFF, len(payload) >> 8, sequence))
    header.append(crc8(header))
    frame = header + struct.pack("<H", command_id) + payload
    frame += struct.pack("<H", crc16(frame))
    return bytes(frame)


class ProtocolTests(unittest.TestCase):
    def test_fragmented_frame_and_noise(self) -> None:
        raw = make_frame(0x0201, struct.pack("<BBHHH", 3, 2, 275, 400, 50))
        parser = RefereeFrameParser()
        self.assertEqual(parser.feed(b"noise" + raw[:6]), [])
        frames = parser.feed(raw[6:])
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0].command_id, 0x0201)
        self.assertEqual(parser.valid_frames, 1)

    def test_bad_crc_is_rejected(self) -> None:
        raw = bytearray(make_frame(0x0002, b"\x01"))
        raw[-1] ^= 0xFF
        parser = RefereeFrameParser()
        self.assertEqual(parser.feed(raw), [])
        self.assertEqual(parser.bad_crc16, 1)

    def test_hp_and_coins_decode(self) -> None:
        robot = decode_frame(ParsedFrame(0x0201, 1, struct.pack("<BBHH", 103, 3, 320, 500)))
        economy = decode_frame(ParsedFrame(0x0208, 2, struct.pack("<HHH", 120, 8, 450)))
        self.assertEqual(robot["current_hp"], 320)
        self.assertEqual(robot["maximum_hp"], 500)
        self.assertEqual(economy["coins"], 450)


if __name__ == "__main__":
    unittest.main()
