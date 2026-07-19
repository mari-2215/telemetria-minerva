from __future__ import annotations

from pathlib import Path
import tempfile

from minerva_api.store import TelemetryStore


def _start(
    store: TelemetryStore,
    started_at: str = "2026-07-19T12:00:00Z",
) -> str:
    recording_id = "rec-inactivity-test"
    store.start_recording(
        recording_id=recording_id,
        boat_id="azimutal-01",
        name="Rota parada",
        strategy="balanced",
        cruise_throttle=0.55,
        actor="Capitã",
        now=started_at,
    )
    return recording_id


def _insert_points(
    store: TelemetryStore,
    recording_id: str,
    count: int,
) -> None:
    values = [
        (
            recording_id,
            index,
            f"2026-07-19T12:00:0{index}Z",
            -22.8000 + index * 0.0001,
            -43.2000,
        )
        for index in range(count)
    ]
    with store._lock, store._connection:
        store._connection.executemany(
            "INSERT INTO route_recording_points("
            "recording_id, point_index, recorded_at, latitude, longitude"
            ") VALUES (?, ?, ?, ?, ?)",
            values,
        )


def test_discards_recording_with_two_points_after_five_seconds() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "telemetry.db")
        recording_id = _start(store)
        _insert_points(store, recording_id, 2)

        expired = store.expire_stale_recording(
            "azimutal-01",
            now="2026-07-19T12:00:06.100000Z",
        )

        assert expired == recording_id
        recording = store.recording(recording_id)
        assert recording is not None
        assert recording["status"] == "discarded"
        store.close()


def test_keeps_recording_after_three_distinct_points() -> None:
    with tempfile.TemporaryDirectory() as directory:
        store = TelemetryStore(Path(directory) / "telemetry.db")
        recording_id = _start(store)
        _insert_points(store, recording_id, 3)

        expired = store.expire_stale_recording(
            "azimutal-01",
            now="2026-07-19T12:00:20Z",
        )

        assert expired is None
        recording = store.recording(recording_id)
        assert recording is not None
        assert recording["status"] == "recording"
        store.close()
