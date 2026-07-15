from __future__ import annotations

import json
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
                waypoints TEXT NOT NULL,
                created_at TEXT NOT NULL,
                created_by TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_missions_boat_status
                ON missions(boat_id, status, created_at DESC);
            """
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
                    mission_id, boat_id, name, status, cruise_throttle,
                    waypoints, created_at, created_by, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    mission["mission_id"],
                    mission["boat_id"],
                    mission["name"],
                    mission["status"],
                    mission["cruise_throttle"],
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

    def activate_mission(self, mission_id: str, now: str) -> dict[str, Any] | None:
        mission = self.mission(mission_id)
        if mission is None:
            return None
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE missions SET status = 'cancelled', updated_at = ?
                WHERE boat_id = ? AND status IN ('pending', 'active') AND mission_id != ?
                """,
                (now, mission["boat_id"], mission_id),
            )
            self._connection.execute(
                "UPDATE missions SET status = 'pending', updated_at = ?, last_error = NULL WHERE mission_id = ?",
                (now, mission_id),
            )
        return self.mission(mission_id)

    def update_mission_status(
        self, mission_id: str, mission_status: str, now: str, error: str | None = None
    ) -> dict[str, Any] | None:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE missions SET status = ?, updated_at = ?, last_error = ? WHERE mission_id = ?",
                (mission_status, now, error[:500] if error else None, mission_id),
            )
        return self.mission(mission_id) if cursor.rowcount == 1 else None

    def close(self) -> None:
        self._connection.close()
