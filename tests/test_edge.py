import json
from pathlib import Path
import tempfile
import unittest

from minerva_boat import BoatTelemetryService, OutboxStore
from minerva_protocol import Frame, MessageType, encode_frame


def payload(sequence: int = 1) -> bytes:
    return json.dumps(
        {
            "schema_version": 1,
            "boat_id": "azimutal-01",
            "sequence": sequence,
            "recorded_at": "2026-07-14T20:00:00Z",
            "position": {"latitude_deg": -22.8, "longitude_deg": -43.2},
            "status": {"severity": "ok", "alarms": []},
        }
    ).encode()


class EdgeServiceTest(unittest.TestCase):
    def test_persists_once_and_detects_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OutboxStore(Path(directory) / "outbox.db")
            service = BoatTelemetryService(store)
            frame = encode_frame(Frame(MessageType.TELEMETRY, 1, 10, payload()))
            self.assertEqual(service.ingest_serial_bytes(frame), 1)
            self.assertEqual(service.ingest_serial_bytes(frame), 0)
            self.assertEqual(store.count(), 1)
            self.assertEqual(service.stats.duplicates, 1)
            self.assertEqual(store.pending()[0]["payload"]["boat_id"], "azimutal-01")
            store.close()

    def test_replaces_arduino_placeholder_time_with_pi_utc(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OutboxStore(Path(directory) / "outbox.db")
            service = BoatTelemetryService(store)
            value = json.loads(payload())
            value["recorded_at"] = "1970-01-01T00:00:00Z"
            frame = encode_frame(Frame(MessageType.TELEMETRY, 1, 10, json.dumps(value).encode()))
            self.assertEqual(service.ingest_serial_bytes(frame), 1)
            self.assertFalse(store.pending()[0]["payload"]["recorded_at"].startswith("1970-"))
            store.close()

    def test_rejects_invalid_position(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OutboxStore(Path(directory) / "outbox.db")
            service = BoatTelemetryService(store)
            value = json.loads(payload())
            value["position"]["latitude_deg"] = 100
            frame = encode_frame(Frame(MessageType.TELEMETRY, 1, 10, json.dumps(value).encode()))
            self.assertEqual(service.ingest_serial_bytes(frame), 0)
            self.assertEqual(service.stats.invalid_payloads, 1)
            store.close()


if __name__ == "__main__":
    unittest.main()
