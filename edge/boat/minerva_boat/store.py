from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import threading
from typing import Any

from minerva_protocol import Telemetry


class OutboxStore:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        self._lock = threading.Lock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=FULL")
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                boat_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                recorded_at TEXT NOT NULL,
                payload TEXT NOT NULL,
                sent_at TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                UNIQUE(boat_id, sequence)
            );
            CREATE TABLE IF NOT EXISTS deliveries (
                sample_id INTEGER NOT NULL REFERENCES samples(id) ON DELETE CASCADE,
                target TEXT NOT NULL,
                sent_at TEXT,
                discarded_at TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                PRIMARY KEY(sample_id, target)
            );
            CREATE INDEX IF NOT EXISTS idx_deliveries_unsent ON deliveries(target, sent_at, sample_id);
            CREATE TABLE IF NOT EXISTS missions (
                mission_id TEXT PRIMARY KEY,
                boat_id TEXT NOT NULL,
                status TEXT NOT NULL,
                waypoint_index INTEGER NOT NULL DEFAULT 0,
                payload TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_edge_missions_active
                ON missions(boat_id, status, updated_at DESC);
            CREATE TABLE IF NOT EXISTS recordings (
                recording_id TEXT PRIMARY KEY,
                boat_id TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                uploaded_at TEXT
            );
            CREATE TABLE IF NOT EXISTS recording_points (
                recording_id TEXT NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
                point_index INTEGER NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                PRIMARY KEY(recording_id, point_index)
            );
            """
        )
        delivery_columns = {row[1] for row in self._connection.execute("PRAGMA table_info(deliveries)")}
        if "discarded_at" not in delivery_columns:
            self._connection.execute("ALTER TABLE deliveries ADD COLUMN discarded_at TEXT")

    def append(self, telemetry: Telemetry) -> bool:
        payload = json.dumps(telemetry.data, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "INSERT OR IGNORE INTO samples(boat_id, sequence, recorded_at, payload) VALUES (?, ?, ?, ?)",
                (telemetry.boat_id, telemetry.sequence, telemetry.recorded_at, payload),
            )
            return cursor.rowcount == 1

    def pending(self, limit: int = 100, target: str = "cloud") -> list[dict[str, Any]]:
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT OR IGNORE INTO deliveries(sample_id, target) SELECT id, ? FROM samples",
                (target,),
            )
        rows = self._connection.execute(
            """
            SELECT s.id, s.payload, d.attempts
            FROM samples s
            JOIN deliveries d ON d.sample_id = s.id
            WHERE d.target = ? AND d.sent_at IS NULL AND d.discarded_at IS NULL
            ORDER BY s.id LIMIT ?
            """,
            (target, limit),
        ).fetchall()
        return [{"id": row["id"], "payload": json.loads(row["payload"]), "attempts": row["attempts"]} for row in rows]

    def mark_discarded(self, row_ids: list[int], discarded_at: str, target: str) -> None:
        if not row_ids:
            return
        placeholders = ",".join("?" for _ in row_ids)
        with self._lock, self._connection:
            self._connection.execute(
                f"UPDATE deliveries SET discarded_at = ? WHERE target = ? AND sample_id IN ({placeholders})",
                (discarded_at, target, *row_ids),
            )

    def mark_sent(self, row_id: int, sent_at: str, target: str = "cloud") -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE deliveries SET sent_at = ?, last_error = NULL WHERE sample_id = ? AND target = ?",
                (sent_at, row_id, target),
            )

    def mark_failed(self, row_id: int, error: str, target: str = "cloud") -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE deliveries SET attempts = attempts + 1, last_error = ? WHERE sample_id = ? AND target = ?",
                (error[:500], row_id, target),
            )

    def count(self) -> int:
        return int(self._connection.execute("SELECT COUNT(*) FROM samples").fetchone()[0])

    def save_mission(self, mission: dict[str, Any]) -> None:
        payload = json.dumps(mission, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE missions SET status = 'cancelled', updated_at = CURRENT_TIMESTAMP WHERE boat_id = ? AND status = 'active'",
                (mission["boat_id"],),
            )
            self._connection.execute(
                """
                INSERT INTO missions(mission_id, boat_id, status, waypoint_index, payload)
                VALUES (?, ?, 'active', 0, ?)
                ON CONFLICT(mission_id) DO UPDATE SET
                    status = 'active', payload = excluded.payload, updated_at = CURRENT_TIMESTAMP
                """,
                (mission["mission_id"], mission["boat_id"], payload),
            )

    def active_mission(self, boat_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            "SELECT payload, waypoint_index FROM missions WHERE boat_id = ? AND status = 'active' ORDER BY updated_at DESC LIMIT 1",
            (boat_id,),
        ).fetchone()
        if row is None:
            return None
        result = json.loads(row["payload"])
        result["waypoint_index"] = row["waypoint_index"]
        result["status"] = "active"
        return result

    def set_mission_progress(self, mission_id: str, waypoint_index: int) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE missions SET waypoint_index = ?, updated_at = CURRENT_TIMESTAMP WHERE mission_id = ?",
                (waypoint_index, mission_id),
            )

    def finish_mission(self, mission_id: str, mission_status: str = "completed") -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE missions SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE mission_id = ?",
                (mission_status, mission_id),
            )

    def capture_recording(self, telemetry: Telemetry) -> None:
        control = telemetry.data.get("control") or {}
        position = telemetry.data.get("position") or {}
        recording_active = bool(control.get("recording_active"))
        with self._lock, self._connection:
            active = self._connection.execute(
                "SELECT recording_id FROM recordings WHERE boat_id = ? AND status = 'recording' ORDER BY started_at DESC LIMIT 1",
                (telemetry.boat_id,),
            ).fetchone()
            if not recording_active:
                if active:
                    self._connection.execute(
                        "UPDATE recordings SET status = 'ready', finished_at = ? WHERE recording_id = ?",
                        (telemetry.recorded_at, active["recording_id"]),
                    )
                return
            if "latitude_deg" not in position or "longitude_deg" not in position:
                return
            if active is None:
                recording_id = f"rec-{telemetry.boat_id}-{telemetry.sequence}"[:32]
                self._connection.execute(
                    "INSERT OR IGNORE INTO recordings(recording_id, boat_id, status, started_at) VALUES (?, ?, 'recording', ?)",
                    (recording_id, telemetry.boat_id, telemetry.recorded_at),
                )
            else:
                recording_id = active["recording_id"]
            last = self._connection.execute(
                "SELECT point_index, latitude, longitude FROM recording_points WHERE recording_id = ? ORDER BY point_index DESC LIMIT 1",
                (recording_id,),
            ).fetchone()
            if last and last["point_index"] >= 199:
                return
            latitude = float(position["latitude_deg"])
            longitude = float(position["longitude_deg"])
            # Aproximadamente 2 m: evita uma nuvem de pontos quando o GPS esta parado.
            if last and abs(latitude - last["latitude"]) < 0.000018 and abs(longitude - last["longitude"]) < 0.000018:
                return
            point_index = 0 if last is None else int(last["point_index"]) + 1
            self._connection.execute(
                "INSERT INTO recording_points(recording_id, point_index, latitude, longitude) VALUES (?, ?, ?, ?)",
                (recording_id, point_index, latitude, longitude),
            )

    def pending_recordings(self) -> list[dict[str, Any]]:
        rows = self._connection.execute(
            "SELECT * FROM recordings WHERE status = 'ready' AND uploaded_at IS NULL ORDER BY started_at"
        ).fetchall()
        result: list[dict[str, Any]] = []
        for row in rows:
            points = self._connection.execute(
                "SELECT latitude, longitude FROM recording_points WHERE recording_id = ? ORDER BY point_index",
                (row["recording_id"],),
            ).fetchall()
            if points:
                result.append(
                    {
                        "mission_id": row["recording_id"],
                        "boat_id": row["boat_id"],
                        "name": f"Trajeto gravado {row['started_at']}",
                        "cruise_throttle": 0.35,
                        "waypoints": [
                            {"latitude_deg": point["latitude"], "longitude_deg": point["longitude"], "tolerance_m": 8.0}
                            for point in points
                        ],
                    }
                )
        return result

    def mark_recording_uploaded(self, recording_id: str, uploaded_at: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE recordings SET uploaded_at = ? WHERE recording_id = ?",
                (uploaded_at, recording_id),
            )

    def close(self) -> None:
        self._connection.close()
