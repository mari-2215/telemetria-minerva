from __future__ import annotations

from pathlib import Path

from minerva_api.store import TelemetryStore
from minerva_boat.autopilot import fuzzy_navigation_output
from minerva_protocol import Mission, Telemetry


def test_best_time_strategy_keeps_more_power_on_a_straight() -> None:
    _, balanced = fuzzy_navigation_output(8.0, 70.0, 0.80, "balanced")
    _, best_time = fuzzy_navigation_output(8.0, 70.0, 0.80, "best_time")
    assert best_time > balanced
    assert best_time <= 0.80


def test_mission_round_trip_preserves_strategy() -> None:
    mission = Mission.from_dict(
        {
            "mission_id": "route-01",
            "boat_id": "azimutal-01",
            "name": "Volta rápida",
            "strategy": "best_time",
            "cruise_throttle": 0.75,
            "status": "draft",
            "waypoints": [
                {"latitude_deg": -26.30, "longitude_deg": -48.84, "tolerance_m": 6.0},
                {"latitude_deg": -26.31, "longitude_deg": -48.85, "tolerance_m": 6.0},
            ],
        }
    )
    assert mission.strategy == "best_time"
    assert mission.to_dict()["strategy"] == "best_time"


def _telemetry(sequence: int, latitude: float, longitude: float) -> Telemetry:
    return Telemetry.from_dict(
        {
            "schema_version": 1,
            "boat_id": "azimutal-01",
            "sequence": sequence,
            "recorded_at": f"2026-07-19T12:00:{sequence:02d}Z",
            "position": {"latitude_deg": latitude, "longitude_deg": longitude},
            "status": {"severity": "ok", "alarms": []},
        }
    )


def test_backend_recording_is_exclusive_and_becomes_a_mission(tmp_path: Path) -> None:
    store = TelemetryStore(tmp_path / "backend.db")
    recording = store.start_recording(
        recording_id="rec-test",
        boat_id="azimutal-01",
        name="Trajetória da prova",
        strategy="best_time",
        cruise_throttle=0.70,
        actor="Capitã",
        now="2026-07-19T12:00:00Z",
    )
    assert recording["status"] == "recording"

    store.insert(_telemetry(1, -26.3044, -48.8464))
    store.insert(_telemetry(2, -26.3042, -48.8460))
    result = store.stop_recording("rec-test", "Capitã", "2026-07-19T12:01:00Z")

    assert result is not None
    assert result["mission"]["strategy"] == "best_time"
    assert len(result["mission"]["waypoints"]) == 2
    assert store.active_recording("azimutal-01") is None
    store.close()
