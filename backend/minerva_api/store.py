from __future__ import annotations

from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sqlite3
import threading
from typing import Any

from minerva_protocol import Telemetry


class TelemetryStore:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        self._lock = threading.Lock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                boat_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                recorded_at TEXT NOT NULL,
                received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                severity TEXT NOT NULL,
                latitude REAL,
                longitude REAL,
                payload TEXT NOT NULL,
                UNIQUE(boat_id, sequence)
            );
            CREATE INDEX IF NOT EXISTS idx_telemetry_boat_time ON telemetry(boat_id, recorded_at DESC);
            CREATE TABLE IF NOT EXISTS alerts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                boat_id TEXT NOT NULL,
                code TEXT NOT NULL,
                severity TEXT NOT NULL,
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                acknowledged_at TEXT,
                acknowledged_by TEXT,
                resolved_at TEXT
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_alerts_active_unique
                ON alerts(boat_id, code) WHERE resolved_at IS NULL;
            CREATE INDEX IF NOT EXISTS idx_alerts_active ON alerts(resolved_at, last_seen DESC);
            CREATE TABLE IF NOT EXISTS missions (
                mission_id TEXT PRIMARY KEY,
                boat_id TEXT NOT NULL,
                name TEXT NOT NULL,
                status TEXT NOT NULL,
                cruise_throttle REAL NOT NULL,
                strategy TEXT NOT NULL DEFAULT 'balanced',
                start_confirmed INTEGER NOT NULL DEFAULT 0,
                waypoints TEXT NOT NULL,
                created_at TEXT NOT NULL,
                created_by TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_missions_boat_status
                ON missions(boat_id, status, created_at DESC);
            CREATE TABLE IF NOT EXISTS route_recordings (
                recording_id TEXT PRIMARY KEY,
                boat_id TEXT NOT NULL,
                name TEXT NOT NULL,
                status TEXT NOT NULL,
                strategy TEXT NOT NULL,
                cruise_throttle REAL NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                created_by TEXT NOT NULL,
                mission_id TEXT
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_recording_per_boat
                ON route_recordings(boat_id) WHERE status = 'recording';
            CREATE TABLE IF NOT EXISTS route_recording_points (
                recording_id TEXT NOT NULL REFERENCES route_recordings(recording_id) ON DELETE CASCADE,
                point_index INTEGER NOT NULL,
                recorded_at TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                PRIMARY KEY(recording_id, point_index)
            );
            """
        )
        mission_columns = {row[1] for row in self._connection.execute("PRAGMA table_info(missions)")}
        if "strategy" not in mission_columns:
            self._connection.execute("ALTER TABLE missions ADD COLUMN strategy TEXT NOT NULL DEFAULT 'balanced'")
        if "start_confirmed" not in mission_columns:
            self._connection.execute(
                "ALTER TABLE missions ADD COLUMN start_confirmed INTEGER NOT NULL DEFAULT 0"
            )

    def insert(self, telemetry: Telemetry) -> bool:
        position = telemetry.data.get("position") or {}
        severity = telemetry.data["status"]["severity"]
        payload = json.dumps(telemetry.data, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                INSERT OR IGNORE INTO telemetry(
                    boat_id, sequence, recorded_at, severity, latitude, longitude, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    telemetry.boat_id,
                    telemetry.sequence,
                    telemetry.recorded_at,
                    severity,
                    position.get("latitude_deg"),
                    position.get("longitude_deg"),
                    payload,
                ),
            )
            inserted = cursor.rowcount == 1
            if inserted:
                self._update_alerts(telemetry)
                self._sync_mission_authorization_from_telemetry(telemetry)
                self._expire_stale_recording_locked(
                    telemetry.boat_id,
                    Telemetry.utc_now(),
                )
                self._capture_active_recording(telemetry)
            return inserted

    def _update_alerts(self, telemetry: Telemetry) -> None:
        status = telemetry.data.get("status") or {}
        active_codes = {str(code) for code in status.get("alarms") or []}
        active_rows = self._connection.execute(
            "SELECT id, code FROM alerts WHERE boat_id = ? AND resolved_at IS NULL",
            (telemetry.boat_id,),
        ).fetchall()
        for row in active_rows:
            if row["code"] not in active_codes:
                self._connection.execute(
                    "UPDATE alerts SET resolved_at = ?, last_seen = ? WHERE id = ?",
                    (telemetry.recorded_at, telemetry.recorded_at, row["id"]),
                )
        for code in active_codes:
            cursor = self._connection.execute(
                "UPDATE alerts SET last_seen = ?, severity = ? WHERE boat_id = ? AND code = ? AND resolved_at IS NULL",
                (telemetry.recorded_at, status.get("severity", "warning"), telemetry.boat_id, code),
            )
            if cursor.rowcount == 0:
                self._connection.execute(
                    "INSERT INTO alerts(boat_id, code, severity, first_seen, last_seen) VALUES (?, ?, ?, ?, ?)",
                    (telemetry.boat_id, code, status.get("severity", "warning"), telemetry.recorded_at, telemetry.recorded_at),
                )

    def _sync_mission_authorization_from_telemetry(self, telemetry: Telemetry) -> None:
        control = telemetry.data.get("control") or {}
        autopilot = telemetry.data.get("autopilot") or {}
        safe_to_keep_authorized = (
            control.get("mode") == "auto"
            and bool(control.get("rc_healthy", False))
            and bool(autopilot.get("latched", False))
        )
        if safe_to_keep_authorized:
            return
        self._connection.execute(
            """
            UPDATE missions
            SET status = CASE WHEN status = 'active' THEN 'pending' ELSE status END,
                start_confirmed = 0,
                updated_at = ?
            WHERE boat_id = ?
              AND status IN ('pending', 'active')
              AND (start_confirmed != 0 OR status = 'active')
            """,
            (telemetry.recorded_at, telemetry.boat_id),
        )

    @staticmethod
    def _distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        radius_m = 6_371_000.0
        phi1 = math.radians(lat1)
        phi2 = math.radians(lat2)
        delta_phi = math.radians(lat2 - lat1)
        delta_lambda = math.radians(lon2 - lon1)
        value = math.sin(delta_phi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
        return radius_m * 2.0 * math.atan2(math.sqrt(value), math.sqrt(max(0.0, 1.0 - value)))

    @staticmethod
    def _recording_timestamp(value: str) -> datetime:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    def _expire_stale_recording_locked(
        self,
        boat_id: str,
        now: str,
        inactivity_seconds: float = 5.0,
    ) -> str | None:
        row = self._connection.execute(
            """
            SELECT r.recording_id, r.started_at,
                   COUNT(p.point_index) AS point_count,
                   MAX(p.recorded_at) AS last_point_at
            FROM route_recordings r
            LEFT JOIN route_recording_points p
              ON p.recording_id = r.recording_id
            WHERE r.boat_id = ? AND r.status = 'recording'
            GROUP BY r.recording_id, r.started_at
            """,
            (boat_id,),
        ).fetchone()
        if row is None:
            return None

        # Até dois pontos ainda não formam uma trajetória confiável.
        # Após o terceiro ponto, uma pausa normal não apaga a rota.
        if int(row["point_count"]) > 2:
            return None

        reference = row["last_point_at"] or row["started_at"]
        elapsed = (
            self._recording_timestamp(now)
            - self._recording_timestamp(str(reference))
        ).total_seconds()
        if elapsed < inactivity_seconds:
            return None

        recording_id = str(row["recording_id"])
        self._connection.execute(
            """
            UPDATE route_recordings
            SET status = 'discarded', finished_at = ?
            WHERE recording_id = ? AND status = 'recording'
            """,
            (now, recording_id),
        )
        return recording_id

    def expire_stale_recording(
        self,
        boat_id: str,
        now: str | None = None,
        inactivity_seconds: float = 5.0,
    ) -> str | None:
        current = now or Telemetry.utc_now()
        with self._lock, self._connection:
            return self._expire_stale_recording_locked(
                boat_id,
                current,
                inactivity_seconds,
            )

    def _capture_active_recording(self, telemetry: Telemetry) -> None:
        position = telemetry.data.get("position") or {}
        if "latitude_deg" not in position or "longitude_deg" not in position:
            return
        active = self._connection.execute(
            "SELECT recording_id FROM route_recordings WHERE boat_id = ? AND status = 'recording'",
            (telemetry.boat_id,),
        ).fetchone()
        if active is None:
            return
        recording_id = active["recording_id"]
        last = self._connection.execute(
            """
            SELECT point_index, latitude, longitude
            FROM route_recording_points
            WHERE recording_id = ?
            ORDER BY point_index DESC LIMIT 1
            """,
            (recording_id,),
        ).fetchone()
        if last and int(last["point_index"]) >= 4999:
            return
        latitude = float(position["latitude_deg"])
        longitude = float(position["longitude_deg"])
        if last and self._distance_m(float(last["latitude"]), float(last["longitude"]), latitude, longitude) < 1.8:
            return
        point_index = 0 if last is None else int(last["point_index"]) + 1
        self._connection.execute(
            """
            INSERT INTO route_recording_points(recording_id, point_index, recorded_at, latitude, longitude)
            VALUES (?, ?, ?, ?, ?)
            """,
            (recording_id, point_index, telemetry.recorded_at, latitude, longitude),
        )

    def boats(self) -> list[dict[str, Any]]:
        rows = self._connection.execute(
            """
            SELECT t.boat_id, t.recorded_at, t.severity, t.latitude, t.longitude
            FROM telemetry t
            INNER JOIN (
                SELECT boat_id, MAX(id) AS max_id FROM telemetry GROUP BY boat_id
            ) latest ON latest.max_id = t.id
            ORDER BY t.boat_id
            """
        ).fetchall()
        return [dict(row) for row in rows]

    def latest(self, boat_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            "SELECT payload FROM telemetry WHERE boat_id = ? ORDER BY id DESC LIMIT 1",
            (boat_id,),
        ).fetchone()
        return json.loads(row["payload"]) if row else None

    def history(self, boat_id: str, limit: int = 500, before_sequence: int | None = None) -> list[dict[str, Any]]:
        if before_sequence is None:
            rows = self._connection.execute(
                "SELECT payload FROM telemetry WHERE boat_id = ? ORDER BY id DESC LIMIT ?",
                (boat_id, limit),
            ).fetchall()
        else:
            rows = self._connection.execute(
                "SELECT payload FROM telemetry WHERE boat_id = ? AND sequence < ? ORDER BY id DESC LIMIT ?",
                (boat_id, before_sequence, limit),
            ).fetchall()
        return [json.loads(row["payload"]) for row in reversed(rows)]

    def alerts(self, active_only: bool = True, limit: int = 500) -> list[dict[str, Any]]:
        where = "WHERE resolved_at IS NULL" if active_only else ""
        rows = self._connection.execute(
            f"SELECT * FROM alerts {where} ORDER BY last_seen DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]

    def acknowledge_alert(self, alert_id: int, acknowledged_at: str, actor: str) -> bool:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE alerts SET acknowledged_at = ?, acknowledged_by = ? WHERE id = ? AND resolved_at IS NULL",
                (acknowledged_at, actor, alert_id),
            )
            return cursor.rowcount == 1

    def create_mission(self, mission: dict[str, Any], actor: str, now: str) -> dict[str, Any]:
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO missions(
                    mission_id, boat_id, name, status, cruise_throttle, strategy,
                    start_confirmed, waypoints, created_at, created_by, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mission["mission_id"],
                    mission["boat_id"],
                    mission["name"],
                    mission["status"],
                    mission["cruise_throttle"],
                    mission.get("strategy", "balanced"),
                    1 if mission.get("start_confirmed", False) else 0,
                    json.dumps(mission["waypoints"], separators=(",", ":")),
                    now,
                    actor,
                    now,
                ),
            )
        created = self.mission(mission["mission_id"])
        assert created is not None
        return created

    @staticmethod
    def _mission_row(row: sqlite3.Row) -> dict[str, Any]:
        value = dict(row)
        value["waypoints"] = json.loads(value["waypoints"])
        value["start_confirmed"] = bool(value.get("start_confirmed", 0))
        return value

    def mission(self, mission_id: str) -> dict[str, Any] | None:
        row = self._connection.execute("SELECT * FROM missions WHERE mission_id = ?", (mission_id,)).fetchone()
        return self._mission_row(row) if row else None

    def missions(self, boat_id: str | None = None, mission_status: str | None = None) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if boat_id:
            clauses.append("boat_id = ?")
            values.append(boat_id)
        if mission_status:
            clauses.append("status = ?")
            values.append(mission_status)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self._connection.execute(
            f"SELECT * FROM missions {where} ORDER BY created_at DESC", values
        ).fetchall()
        return [self._mission_row(row) for row in rows]

    def pending_mission(self, boat_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            "SELECT * FROM missions WHERE boat_id = ? AND status = 'pending' ORDER BY updated_at LIMIT 1",
            (boat_id,),
        ).fetchone()
        return self._mission_row(row) if row else None

    def authorized_pending_mission(self, boat_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            """
            SELECT * FROM missions
            WHERE boat_id = ? AND status = 'pending' AND start_confirmed = 1
            ORDER BY updated_at LIMIT 1
            """,
            (boat_id,),
        ).fetchone()
        return self._mission_row(row) if row else None

    def activate_mission(self, mission_id: str, now: str) -> dict[str, Any] | None:
        mission = self.mission(mission_id)
        if mission is None:
            return None
        active = self._connection.execute(
            "SELECT mission_id FROM missions WHERE boat_id = ? AND status = 'active' AND mission_id != ? LIMIT 1",
            (mission["boat_id"], mission_id),
        ).fetchone()
        if active is not None:
            raise RuntimeError("an active mission must be stopped before another route is sent")
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE missions
                SET status = 'cancelled', start_confirmed = 0, updated_at = ?
                WHERE boat_id = ? AND status IN ('pending', 'active') AND mission_id != ?
                """,
                (now, mission["boat_id"], mission_id),
            )
            self._connection.execute(
                """
                UPDATE missions
                SET status = 'pending', start_confirmed = 0, updated_at = ?, last_error = NULL
                WHERE mission_id = ?
                """,
                (now, mission_id),
            )
        return self.mission(mission_id)

    def configure_mission(
        self,
        mission_id: str,
        strategy: str,
        cruise_throttle: float,
        now: str,
    ) -> dict[str, Any] | None:
        mission = self.mission(mission_id)
        if mission is None:
            return None
        if mission["status"] == "active" or mission["start_confirmed"]:
            raise RuntimeError("active or authorized mission cannot be configured")
        if strategy not in {"balanced", "best_time"}:
            raise ValueError("invalid strategy")
        if strategy == "best_time":
            cruise_throttle = 1.0
        elif not 0.15 <= cruise_throttle <= 0.85:
            raise ValueError("limited power must be between 0.15 and 0.85")
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE missions SET strategy = ?, cruise_throttle = ?, updated_at = ? WHERE mission_id = ?",
                (strategy, cruise_throttle, now, mission_id),
            )
        return self.mission(mission_id)

    def set_mission_ready(self, mission_id: str, ready: bool, now: str) -> dict[str, Any] | None:
        mission = self.mission(mission_id)
        if mission is None:
            return None
        if mission["status"] not in {"pending", "active"}:
            raise RuntimeError("mission must be pending or active")
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE missions SET start_confirmed = ?, updated_at = ? WHERE mission_id = ?",
                (1 if ready else 0, now, mission_id),
            )
        return self.mission(mission_id)

    def delete_mission(self, mission_id: str) -> bool:
        mission = self.mission(mission_id)
        if mission is None:
            return False
        if mission["status"] == "active" or mission["start_confirmed"]:
            raise RuntimeError("active or authorized mission cannot be deleted")
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE route_recordings SET mission_id = NULL WHERE mission_id = ?",
                (mission_id,),
            )
            cursor = self._connection.execute(
                "DELETE FROM missions WHERE mission_id = ?",
                (mission_id,),
            )
        return cursor.rowcount == 1

    def update_mission_status(
        self, mission_id: str, mission_status: str, now: str, error: str | None = None
    ) -> dict[str, Any] | None:
        with self._lock, self._connection:
            if mission_status == "active":
                cursor = self._connection.execute(
                    "UPDATE missions SET status = ?, updated_at = ?, last_error = ? WHERE mission_id = ?",
                    (mission_status, now, error[:500] if error else None, mission_id),
                )
            else:
                cursor = self._connection.execute(
                    """
                    UPDATE missions
                    SET status = ?, start_confirmed = 0, updated_at = ?, last_error = ?
                    WHERE mission_id = ?
                    """,
                    (mission_status, now, error[:500] if error else None, mission_id),
                )
        return self.mission(mission_id) if cursor.rowcount == 1 else None

    @staticmethod
    def _recording_row(row: sqlite3.Row, points: list[sqlite3.Row]) -> dict[str, Any]:
        value = dict(row)
        value["points"] = [
            {
                "latitude_deg": float(point["latitude"]),
                "longitude_deg": float(point["longitude"]),
                "recorded_at": point["recorded_at"],
            }
            for point in points
        ]
        value["point_count"] = len(points)
        return value

    def recording(self, recording_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            "SELECT * FROM route_recordings WHERE recording_id = ?", (recording_id,)
        ).fetchone()
        if row is None:
            return None
        points = self._connection.execute(
            "SELECT * FROM route_recording_points WHERE recording_id = ? ORDER BY point_index",
            (recording_id,),
        ).fetchall()
        return self._recording_row(row, points)

    def active_recording(self, boat_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection:
            self._expire_stale_recording_locked(
                boat_id,
                Telemetry.utc_now(),
            )
            row = self._connection.execute(
                "SELECT * FROM route_recordings WHERE boat_id = ? AND status = 'recording'",
                (boat_id,),
            ).fetchone()
            if row is None:
                return None
            points = self._connection.execute(
                "SELECT * FROM route_recording_points WHERE recording_id = ? ORDER BY point_index",
                (row["recording_id"],),
            ).fetchall()
            return self._recording_row(row, points)

    def start_recording(
        self,
        recording_id: str,
        boat_id: str,
        name: str,
        strategy: str,
        cruise_throttle: float,
        actor: str,
        now: str,
    ) -> dict[str, Any]:
        if strategy not in {"balanced", "best_time"}:
            raise ValueError("invalid strategy")
        if not 0.0 <= cruise_throttle <= 1.0:
            raise ValueError("invalid cruise throttle")
        with self._lock, self._connection:
            active = self._connection.execute(
                "SELECT recording_id FROM route_recordings WHERE boat_id = ? AND status = 'recording'",
                (boat_id,),
            ).fetchone()
            if active is not None:
                raise RuntimeError("recording already active")
            self._connection.execute(
                """
                INSERT INTO route_recordings(
                    recording_id, boat_id, name, status, strategy,
                    cruise_throttle, started_at, created_by
                ) VALUES (?, ?, ?, 'recording', ?, ?, ?, ?)
                """,
                (recording_id, boat_id, name[:80], strategy, cruise_throttle, now, actor),
            )
        created = self.recording(recording_id)
        assert created is not None
        return created

    @staticmethod
    def _downsample_points(points: list[sqlite3.Row], limit: int = 200) -> list[sqlite3.Row]:
        if len(points) <= limit:
            return points
        indexes = [round(index * (len(points) - 1) / (limit - 1)) for index in range(limit)]
        return [points[index] for index in indexes]

    def stop_recording(self, recording_id: str, actor: str, now: str) -> dict[str, Any] | None:
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT * FROM route_recordings WHERE recording_id = ?", (recording_id,)
            ).fetchone()
            if row is None:
                return None
            if row["status"] != "recording":
                raise RuntimeError("recording is not active")
            points = self._connection.execute(
                "SELECT * FROM route_recording_points WHERE recording_id = ? ORDER BY point_index",
                (recording_id,),
            ).fetchall()
            if len(points) < 2:
                raise ValueError("recording needs at least two GPS points")
            self._connection.execute(
                "UPDATE route_recordings SET status = 'ready', finished_at = ? WHERE recording_id = ?",
                (now, recording_id),
            )

        sampled = self._downsample_points(points)
        mission_id = f"route-{recording_id}"[:32]
        mission = {
            "mission_id": mission_id,
            "boat_id": row["boat_id"],
            "name": row["name"],
            "status": "draft",
            "cruise_throttle": float(row["cruise_throttle"]),
            "strategy": row["strategy"],
            "waypoints": [
                {
                    "latitude_deg": float(point["latitude"]),
                    "longitude_deg": float(point["longitude"]),
                    "tolerance_m": 6.0,
                }
                for point in sampled
            ],
        }
        created_mission = self.create_mission(mission, actor, now)
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE route_recordings SET mission_id = ? WHERE recording_id = ?",
                (mission_id, recording_id),
            )
        recording = self.recording(recording_id)
        assert recording is not None
        return {"recording": recording, "mission": created_mission}

    def close(self) -> None:
        self._connection.close()
