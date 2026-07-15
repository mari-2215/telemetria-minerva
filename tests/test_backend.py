import tempfile
from pathlib import Path

from fastapi.testclient import TestClient

from minerva_api import create_app
from minerva_api.store import TelemetryStore


def sample(sequence: int = 1):
    return {
        "schema_version": 1,
        "boat_id": "azimutal-01",
        "sequence": sequence,
        "recorded_at": "2026-07-14T20:00:00Z",
        "position": {"latitude_deg": -22.8, "longitude_deg": -43.2},
        "power": {"battery_v": 12.5, "current_a": 4.0},
        "status": {"severity": "ok", "alarms": []},
    }


def test_ingest_auth_deduplication_and_queries():
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            assert client.post("/v1/ingest", json=sample()).status_code == 401
            response = client.post("/v1/ingest", json=sample(), headers={"X-Device-Token": "dev-device-token"})
            assert response.status_code == 201
            assert response.json() == {"accepted": True, "duplicate": False}
            duplicate = client.post("/v1/ingest", json=sample(), headers={"X-Device-Token": "dev-device-token"})
            assert duplicate.json() == {"accepted": False, "duplicate": True}
            headers = {"Authorization": "Bearer dev-viewer-token"}
            assert client.get("/v1/boats", headers=headers).json()[0]["boat_id"] == "azimutal-01"
            assert client.get("/v1/boats/azimutal-01/latest", headers=headers).json()["sequence"] == 1
            assert len(client.get("/v1/boats/azimutal-01/samples", headers=headers).json()) == 1
        store.close()


def test_invalid_payload_rejected():
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            invalid = sample()
            invalid["position"]["latitude_deg"] = 500
            response = client.post("/v1/ingest", json=invalid, headers={"X-Device-Token": "dev-device-token"})
            assert response.status_code == 422
        store.close()


def test_roles_and_alert_acknowledgement(monkeypatch):
    monkeypatch.setenv(
        "MINERVA_ACCESS_TOKENS_JSON",
        '{"read-token":{"name":"Leitor","role":"read"},"lab-token":{"name":"Lab","role":"laboratory"}}',
    )
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            critical = sample(2)
            critical["status"] = {"severity": "critical", "alarms": ["WATER_DETECTED"]}
            client.post("/v1/ingest", json=critical, headers={"X-Device-Token": "dev-device-token"})
            read_headers = {"Authorization": "Bearer read-token"}
            alerts = client.get("/v1/alerts", headers=read_headers).json()
            assert alerts[0]["code"] == "WATER_DETECTED"
            assert client.post(f"/v1/alerts/{alerts[0]['id']}/ack", headers=read_headers).status_code == 403
            lab_headers = {"Authorization": "Bearer lab-token"}
            assert client.get("/v1/me", headers=lab_headers).json() == {"name": "Lab", "role": "laboratory"}
            assert client.post(f"/v1/alerts/{alerts[0]['id']}/ack", headers=lab_headers).json() == {"acknowledged": True}
        store.close()
