from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
from typing import Any


class TelemetryValidationError(ValueError):
    pass


def _finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TelemetryValidationError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise TelemetryValidationError(f"{name} must be finite")
    return result


@dataclass(frozen=True, slots=True)
class Telemetry:
    boat_id: str
    sequence: int
    recorded_at: str
    data: dict[str, Any]
    schema_version: int = 1

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Telemetry":
        if value.get("schema_version") != 1:
            raise TelemetryValidationError("unsupported schema_version")
        boat_id = value.get("boat_id")
        if not isinstance(boat_id, str) or not 1 <= len(boat_id) <= 32:
            raise TelemetryValidationError("invalid boat_id")
        sequence = value.get("sequence")
        if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
            raise TelemetryValidationError("invalid sequence")
        recorded_at = value.get("recorded_at")
        if not isinstance(recorded_at, str):
            raise TelemetryValidationError("invalid recorded_at")
        try:
            parsed = datetime.fromisoformat(recorded_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise TelemetryValidationError("invalid recorded_at") from exc
        if parsed.tzinfo is None:
            raise TelemetryValidationError("recorded_at must include timezone")

        status = value.get("status")
        if not isinstance(status, dict) or status.get("severity") not in {"ok", "warning", "critical"}:
            raise TelemetryValidationError("invalid status")

        position = value.get("position")
        if position is not None:
            if not isinstance(position, dict):
                raise TelemetryValidationError("position must be an object")
            latitude = _finite_number(position.get("latitude_deg"), "latitude_deg")
            longitude = _finite_number(position.get("longitude_deg"), "longitude_deg")
            if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
                raise TelemetryValidationError("position outside valid range")

        return cls(boat_id, sequence, recorded_at, dict(value), 1)

    @classmethod
    def from_json_bytes(cls, payload: bytes) -> "Telemetry":
        try:
            decoded = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise TelemetryValidationError("invalid JSON payload") from exc
        if not isinstance(decoded, dict):
            raise TelemetryValidationError("payload root must be an object")
        return cls.from_dict(decoded)

    def to_json_bytes(self) -> bytes:
        return json.dumps(self.data, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")

    @staticmethod
    def utc_now() -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

