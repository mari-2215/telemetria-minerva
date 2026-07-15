import json
import unittest

from minerva_protocol import AutopilotCommand, Frame, FrameDecoder, MessageType, crc16_ccitt, encode_frame


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

    def test_autopilot_command_uses_message_type_five(self) -> None:
        encoded = AutopilotCommand(7, 62.5, 0.4, 500, "rota-01", 2).to_frame(1234)
        frame = FrameDecoder().feed(encoded)[0]
        self.assertEqual(frame.message_type, MessageType.AUTOPILOT_COMMAND)
        self.assertEqual(json.loads(frame.payload)["mission_id"], "rota-01")


if __name__ == "__main__":
    unittest.main()
