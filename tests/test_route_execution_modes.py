from pathlib import Path
import tempfile

from fastapi.testclient import TestClient

from minerva_api import create_app
from minerva_api.store import TelemetryStore


HEADERS = {"Authorization": "Bearer dev-viewer-token"}


def _mission() -> dict:
    return {
        "boat_id": "azimutal-01",
        "name": "Perfil de potência",
        "cruise_throttle": 0.40,
        "strategy": "balanced",
        "waypoints": [
            {
                "latitude_deg": -26.3040,
                "longitude_deg": -48.8460,
                "tolerance_m": 6,
            }
        ],
    }


def test_route_execution_mode_can_be_configured_before_send() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            created = client.post(
                "/v1/missions",
                json=_mission(),
                headers=HEADERS,
            ).json()

            best_time = client.post(
                f"/v1/missions/{created['mission_id']}/configure",
                json={
                    "strategy": "best_time",
                    "cruise_throttle": 0.20,
                },
                headers=HEADERS,
            ).json()
            assert best_time["strategy"] == "best_time"
            assert best_time["cruise_throttle"] == 1.0

            limited = client.post(
                f"/v1/missions/{created['mission_id']}/configure",
                json={
                    "strategy": "balanced",
                    "cruise_throttle": 0.65,
                },
                headers=HEADERS,
            ).json()
            assert limited["strategy"] == "balanced"
            assert limited["cruise_throttle"] == 0.65
        store.close()


def test_recording_start_does_not_require_execution_settings() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            response = client.post(
                "/v1/boats/azimutal-01/recordings/start",
                json={"name": "Só GPS"},
                headers=HEADERS,
            )
            assert response.status_code == 201
            recording = response.json()
            assert recording["strategy"] == "balanced"
            assert recording["cruise_throttle"] == 0.55
        store.close()
