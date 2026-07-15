from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import struct


PREAMBLE = b"\xA5\x5A"
PROTOCOL_VERSION = 1
MAX_PAYLOAD_BYTES = 1024
_HEADER = struct.Struct("<2sBBHII")
_CRC = struct.Struct("<H")


class MessageType(IntEnum):
    TELEMETRY = 1
    EVENT = 2
    HEARTBEAT = 3
    ACK = 4


@dataclass(frozen=True, slots=True)
class Frame:
    message_type: MessageType
    sequence: int
    monotonic_ms: int
    payload: bytes
    version: int = PROTOCOL_VERSION


def crc16_ccitt(data: bytes, initial: int = 0xFFFF) -> int:
    crc = initial
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode_frame(frame: Frame) -> bytes:
    if not 0 <= frame.sequence <= 0xFFFFFFFF:
        raise ValueError("sequence must fit uint32")
    if not 0 <= frame.monotonic_ms <= 0xFFFFFFFF:
        raise ValueError("monotonic_ms must fit uint32")
    if len(frame.payload) > MAX_PAYLOAD_BYTES:
        raise ValueError("payload too large")

    header = _HEADER.pack(
        PREAMBLE,
        frame.version,
        int(frame.message_type),
        len(frame.payload),
        frame.sequence,
        frame.monotonic_ms,
    )
    checksum = crc16_ccitt(header[2:] + frame.payload)
    return header + frame.payload + _CRC.pack(checksum)


class FrameDecoder:
    """Incremental decoder that resynchronizes after noise or a corrupt frame."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self.crc_errors = 0
        self.format_errors = 0

    def feed(self, data: bytes) -> list[Frame]:
        self._buffer.extend(data)
        frames: list[Frame] = []

        while True:
            start = self._buffer.find(PREAMBLE)
            if start < 0:
                if self._buffer[-1:] == PREAMBLE[:1]:
                    self._buffer[:] = self._buffer[-1:]
                else:
                    self._buffer.clear()
                break
            if start:
                del self._buffer[:start]
            if len(self._buffer) < _HEADER.size:
                break

            _, version, raw_type, payload_length, sequence, monotonic_ms = _HEADER.unpack_from(self._buffer)
            if version != PROTOCOL_VERSION or payload_length > MAX_PAYLOAD_BYTES:
                self.format_errors += 1
                del self._buffer[0]
                continue

            frame_length = _HEADER.size + payload_length + _CRC.size
            if len(self._buffer) < frame_length:
                break

            payload_start = _HEADER.size
            payload_end = payload_start + payload_length
            payload = bytes(self._buffer[payload_start:payload_end])
            expected_crc = _CRC.unpack_from(self._buffer, payload_end)[0]
            actual_crc = crc16_ccitt(bytes(self._buffer[2:payload_end]))
            if expected_crc != actual_crc:
                self.crc_errors += 1
                del self._buffer[0]
                continue

            try:
                message_type = MessageType(raw_type)
            except ValueError:
                self.format_errors += 1
                del self._buffer[:frame_length]
                continue

            frames.append(Frame(message_type, sequence, monotonic_ms, payload, version))
            del self._buffer[:frame_length]

        return frames

