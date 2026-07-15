from __future__ import annotations

from dataclasses import dataclass

from minerva_protocol import FrameDecoder, MessageType, Telemetry, TelemetryValidationError

from .store import OutboxStore


@dataclass(slots=True)
class ServiceStats:
    accepted: int = 0
    duplicates: int = 0
    invalid_payloads: int = 0
    ignored_frames: int = 0


class BoatTelemetryService:
    def __init__(self, store: OutboxStore) -> None:
        self.store = store
        self.decoder = FrameDecoder()
        self.stats = ServiceStats()

    def ingest_serial_bytes(self, data: bytes) -> int:
        accepted_now = 0
        for frame in self.decoder.feed(data):
            if frame.message_type is not MessageType.TELEMETRY:
                self.stats.ignored_frames += 1
                continue
            try:
                telemetry = Telemetry.from_json_bytes(frame.payload)
            except TelemetryValidationError:
                self.stats.invalid_payloads += 1
                continue
            if telemetry.recorded_at.startswith("1970-"):
                normalized = dict(telemetry.data)
                normalized["recorded_at"] = Telemetry.utc_now()
                telemetry = Telemetry.from_dict(normalized)
            if self.store.append(telemetry):
                self.stats.accepted += 1
                accepted_now += 1
            else:
                self.stats.duplicates += 1
        return accepted_now
