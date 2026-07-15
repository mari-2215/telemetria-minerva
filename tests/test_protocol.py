import json
import unittest

from minerva_protocol import Frame, FrameDecoder, MessageType, crc16_ccitt, encode_frame


class FrameProtocolTest(unittest.TestCase):
    def test_known_crc_vector(self) -> None:
        self.assertEqual(crc16_ccitt(b"123456789"), 0x29B1)

    def test_fragmented_round_trip(self) -> None:
        original = Frame(MessageType.TELEMETRY, 42, 123456, b'{"ok":true}')
        encoded = encode_frame(original)
        decoder = FrameDecoder()
        frames = []
        for byte in encoded:
            frames.extend(decoder.feed(bytes([byte])))
        self.assertEqual(frames, [original])

    def test_noise_and_corrupt_frame_resynchronize(self) -> None:
        corrupt = bytearray(encode_frame(Frame(MessageType.HEARTBEAT, 1, 1, b"bad")))
        corrupt[-1] ^= 0xFF
        valid = Frame(MessageType.TELEMETRY, 2, 2, json.dumps({"x": 1}).encode())
        decoder = FrameDecoder()
        frames = decoder.feed(b"noise" + bytes(corrupt) + encode_frame(valid))
        self.assertEqual(frames, [valid])
        self.assertEqual(decoder.crc_errors, 1)


if __name__ == "__main__":
    unittest.main()

