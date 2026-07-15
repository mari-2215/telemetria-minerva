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

    def close(self) -> None:
        self._connection.close()
