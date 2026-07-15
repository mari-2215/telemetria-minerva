import json
from pathlib import Path
import tempfile
import unittest

from minerva_boat import BoatTelemetryService, MissionAutopilot, OutboxStore, navigation_solution
from minerva_protocol import Frame, FrameDecoder, MessageType, Telemetry, encode_frame


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

    def test_autopilot_builds_fresh_command_from_saved_mission(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OutboxStore(Path(directory) / "outbox.db")
            store.save_mission(
                {
                    "mission_id": "rota-01",
                    "boat_id": "azimutal-01",
                    "name": "Reta",
                    "status": "pending",
                    "cruise_throttle": 0.4,
                    "waypoints": [{"latitude_deg": -22.799, "longitude_deg": -43.2, "tolerance_m": 5}],
                }
            )
            value = json.loads(payload())
            value["position"]["course_deg"] = 0.0
            value["control"] = {"mode": "auto", "rc_healthy": True}
            frame_bytes = MissionAutopilot(store, "azimutal-01").build_command(Telemetry.from_dict(value), now=1.0)
            self.assertIsNotNone(frame_bytes)
            frame = FrameDecoder().feed(frame_bytes)[0]
            self.assertEqual(frame.message_type, MessageType.AUTOPILOT_COMMAND)
            command = json.loads(frame.payload)
            self.assertEqual(command["mission_id"], "rota-01")
            self.assertGreater(command["throttle_norm"], 0)
            store.close()

    def test_navigation_solution_points_forward_for_northbound_target(self) -> None:
        solution = navigation_solution(-22.8, -43.2, 0, -22.799, -43.2, 0.5)
        self.assertAlmostEqual(solution.target_pod_deg, 45.0, delta=0.5)
        self.assertGreater(solution.distance_m, 100)

    def test_record_mode_builds_persistent_gps_route(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OutboxStore(Path(directory) / "outbox.db")
            service = BoatTelemetryService(store)
            first = json.loads(payload(10))
            first["control"] = {"mode": "record", "recording_active": True, "rc_healthy": True}
            second = json.loads(payload(11))
            second["position"] = {"latitude_deg": -22.7998, "longitude_deg": -43.1998}
            second["control"] = {"mode": "record", "recording_active": True, "rc_healthy": True}
            stopped = json.loads(payload(12))
            stopped["control"] = {"mode": "manual", "recording_active": False, "rc_healthy": True}
            for sequence, value in enumerate((first, second, stopped), start=10):
                service.ingest_serial_bytes(encode_frame(Frame(MessageType.TELEMETRY, sequence, sequence, json.dumps(value).encode())))
            recording = store.pending_recordings()[0]
            self.assertEqual(recording["mission_id"], "rec-azimutal-01-10")
            self.assertEqual(len(recording["waypoints"]), 2)
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
