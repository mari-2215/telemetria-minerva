import json
from pathlib import Path
import tempfile

from fastapi.testclient import TestClient

from minerva_api import create_app
from minerva_api.store import TelemetryStore
from minerva_boat import MissionAutopilot, OutboxStore
from minerva_protocol import Telemetry


HEADERS = {"Authorization": "Bearer dev-viewer-token"}
DEVICE_HEADERS = {"X-Device-Token": "dev-device-token"}


def mission_payload(name: str = "Rota segura") -> dict:
    return {
        "boat_id": "azimutal-01",
        "name": name,
        "cruise_throttle": 0.55,
        "strategy": "best_time",
        "waypoints": [
            {"latitude_deg": -26.3044, "longitude_deg": -48.8464, "tolerance_m": 6},
            {"latitude_deg": -26.3040, "longitude_deg": -48.8460, "tolerance_m": 6},
        ],
    }


def telemetry(sequence: int, *, mode: str = "auto", rc_healthy: bool = True, latched: bool = True) -> dict:
    return {
        "schema_version": 1,
        "boat_id": "azimutal-01",
        "sequence": sequence,
        "recorded_at": f"2026-07-19T20:00:{sequence:02d}Z",
        "position": {
            "latitude_deg": -26.3044,
            "longitude_deg": -48.8464,
            "course_deg": 0.0,
        },
        "control": {"mode": mode, "rc_healthy": rc_healthy},
        "autopilot": {"latched": latched},
        "status": {"severity": "ok", "alarms": []},
    }


def test_route_requires_captain_confirmation_before_boat_download() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            created = client.post("/v1/missions", json=mission_payload(), headers=HEADERS).json()
            mission_id = created["mission_id"]
            activated = client.post(f"/v1/missions/{mission_id}/activate", headers=HEADERS).json()
            assert activated["status"] == "pending"
            assert activated["start_confirmed"] is False

            legacy_pending = client.get(
                "/v1/boats/azimutal-01/missions/pending",
                headers=DEVICE_HEADERS,
            ).json()
            assert legacy_pending["mission_id"] == mission_id

            authorized = client.get(
                "/v1/boats/azimutal-01/missions/authorized",
                headers=DEVICE_HEADERS,
            )
            assert authorized.json() is None

            confirmed = client.post(
                f"/v1/missions/{mission_id}/ready",
                json={"ready": True},
                headers=HEADERS,
            ).json()
            assert confirmed["start_confirmed"] is True

            authorized = client.get(
                "/v1/boats/azimutal-01/missions/authorized",
                headers=DEVICE_HEADERS,
            ).json()
            assert authorized["mission_id"] == mission_id
        store.close()


def test_unsafe_telemetry_revokes_authorization() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            created = client.post("/v1/missions", json=mission_payload(), headers=HEADERS).json()
            mission_id = created["mission_id"]
            client.post(f"/v1/missions/{mission_id}/activate", headers=HEADERS)
            client.post(f"/v1/missions/{mission_id}/ready", json={"ready": True}, headers=HEADERS)

            response = client.post(
                "/v1/ingest",
                json=telemetry(1, latched=False),
                headers=DEVICE_HEADERS,
            )
            assert response.status_code == 201

            mission = client.get("/v1/missions?boat_id=azimutal-01", headers=HEADERS).json()[0]
            assert mission["status"] == "pending"
            assert mission["start_confirmed"] is False
            assert client.get(
                "/v1/boats/azimutal-01/missions/authorized",
                headers=DEVICE_HEADERS,
            ).json() is None
        store.close()


def test_route_delete_and_active_route_protection() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            draft = client.post("/v1/missions", json=mission_payload("Apagável"), headers=HEADERS).json()
            deleted = client.delete(f"/v1/missions/{draft['mission_id']}", headers=HEADERS)
            assert deleted.json() == {"deleted": True}

            protected = client.post("/v1/missions", json=mission_payload("Protegida"), headers=HEADERS).json()
            client.post(f"/v1/missions/{protected['mission_id']}/activate", headers=HEADERS)
            client.post(
                f"/v1/missions/{protected['mission_id']}/ready",
                json={"ready": True},
                headers=HEADERS,
            )
            blocked = client.delete(f"/v1/missions/{protected['mission_id']}", headers=HEADERS)
            assert blocked.status_code == 409
        store.close()


class _FakeMissionClient:
    def __init__(self) -> None:
        self.ready_updates: list[tuple[str, bool]] = []
        self.status_updates: list[tuple[str, str]] = []

    def set_ready(self, mission_id: str, ready: bool) -> None:
        self.ready_updates.append((mission_id, ready))

    def set_status(self, mission_id: str, status: str, error_message: str | None = None) -> None:
        del error_message
        self.status_updates.append((mission_id, status))


def test_edge_revokes_local_mission_when_latch_turns_off() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = OutboxStore(Path(directory) / "edge.db")
        store.save_mission(
            {
                "mission_id": "route-safe",
                "boat_id": "azimutal-01",
                "name": "Rota segura",
                "status": "pending",
                "cruise_throttle": 0.5,
                "strategy": "balanced",
                "waypoints": [
                    {"latitude_deg": -26.3040, "longitude_deg": -48.8460, "tolerance_m": 6},
                ],
            }
        )
        fake_client = _FakeMissionClient()
        autopilot = MissionAutopilot(store, "azimutal-01", client=fake_client)  # type: ignore[arg-type]
        value = telemetry(2, latched=False)
        command = autopilot.build_command(Telemetry.from_dict(value), now=1.0)
        assert command is None
        assert store.active_mission("azimutal-01") is None
        assert fake_client.ready_updates == [("route-safe", False)]
        assert fake_client.status_updates == [("route-safe", "pending")]
        store.close()
