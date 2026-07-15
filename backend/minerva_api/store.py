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

    def close(self) -> None:
        self._connection.close()
