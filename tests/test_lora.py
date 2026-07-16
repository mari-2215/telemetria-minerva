import base64
import tempfile
from pathlib import Path

from fastapi.testclient import TestClient

from minerva_api import create_app
from minerva_api.store import TelemetryStore
from minerva_protocol import Telemetry, decode_lora_payload, encode_lora_payload


def telemetry() -> Telemetry:
    return Telemetry.from_dict(
        {
            "schema_version": 1,
            "boat_id": "azimutal-01",
            "sequence": 77,
            "recorded_at": "2026-07-14T20:00:00Z",
            "position": {"latitude_deg": -22.8622, "longitude_deg": -43.2302, "speed_mps": 1.23, "course_deg": 271.2, "fix": 3},
            "power": {"battery_v": 12.431, "current_a": 4.212},
            "motion": {"roll_deg": 3.25, "pitch_deg": -1.5, "yaw_deg": 271.2},
            "environment": {"electronics_temp_c": 34.25, "humidity_pct": 55.5, "water_detected": False},
            "propulsion": {"pod_angle_deg": 45.5, "throttle_norm": 0.42, "rc_healthy": True, "failsafe_active": False},
            "status": {"severity": "ok", "alarms": []},
        }
    )


def test_compact_lora_round_trip():
    payload = encode_lora_payload(telemetry())
    assert len(payload) == 43
    decoded = decode_lora_payload(payload, "azimutal-01", rssi_dbm=-91, snr_db=7.5)
    assert decoded.sequence == 77
    assert decoded.data["position"]["latitude_deg"] == -22.8622
    assert decoded.data["power"]["battery_v"] == 12.431
    assert decoded.data["motion"] == {"roll_deg": 3.25, "pitch_deg": -1.5, "yaw_deg": 271.2}
    assert decoded.data["link"] == {"rssi_dbm": -91, "snr_db": 7.5}


def test_decodes_legacy_payload_without_orientation():
    payload = bytearray(encode_lora_payload(telemetry()))
    payload[0] = 1
    decoded = decode_lora_payload(bytes(payload[:-6]), "azimutal-01")
    assert decoded.sequence == 77
    assert "motion" not in decoded.data


def test_chirpstack_webhook_ingests_payload():
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "backend.db")
        with TestClient(create_app(store)) as client:
            body = {
                "deviceInfo": {"deviceName": "azimutal-01", "devEui": "0011223344556677"},
                "data": base64.b64encode(encode_lora_payload(telemetry())).decode(),
                "rxInfo": [{"rssi": -88, "snr": 9.25}],
            }
            response = client.post(
                "/v1/integrations/chirpstack",
                json=body,
                headers={"X-Integration-Token": "dev-chirpstack-token"},
            )
            assert response.status_code == 201
            latest = store.latest("azimutal-01")
            assert latest["link"]["rssi_dbm"] == -88
        store.close()
