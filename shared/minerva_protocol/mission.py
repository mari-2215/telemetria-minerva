from __future__ import annotations

from dataclasses import dataclass
import json
import math
import re
from typing import Any

from .frame import Frame, MessageType, encode_frame


class MissionValidationError(ValueError):
    pass


_SAFE_ID = re.compile(r"^[A-Za-z0-9_.-]+$")
_MISSION_STRATEGIES = {"balanced", "best_time"}
_DRIVE_DIRECTIONS = {"forward", "reverse", "stop"}


def _finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise MissionValidationError(f"{name} must be a finite number")
    return float(value)


@dataclass(frozen=True, slots=True)
class Waypoint:
    latitude_deg: float
    longitude_deg: float
    tolerance_m: float = 8.0

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Waypoint":
        latitude = _finite_number(value.get("latitude_deg"), "latitude_deg")
        longitude = _finite_number(value.get("longitude_deg"), "longitude_deg")
        tolerance = _finite_number(value.get("tolerance_m", 8.0), "tolerance_m")
        if not -90.0 <= latitude <= 90.0:
            raise MissionValidationError("latitude_deg out of range")
        if not -180.0 <= longitude <= 180.0:
            raise MissionValidationError("longitude_deg out of range")
        if not 2.0 <= tolerance <= 100.0:
            raise MissionValidationError("tolerance_m must be between 2 and 100")
        return cls(latitude, longitude, tolerance)

    def to_dict(self) -> dict[str, float]:
        return {
            "latitude_deg": self.latitude_deg,
            "longitude_deg": self.longitude_deg,
            "tolerance_m": self.tolerance_m,
        }


@dataclass(frozen=True, slots=True)
class Mission:
    mission_id: str
    boat_id: str
    name: str
    waypoints: tuple[Waypoint, ...]
    cruise_throttle: float = 0.45
    status: str = "draft"
    strategy: str = "balanced"

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Mission":
        mission_id = value.get("mission_id")
        boat_id = value.get("boat_id")
        name = value.get("name")
        raw_waypoints = value.get("waypoints")
        status = value.get("status", "draft")
        strategy = value.get("strategy", "balanced")
        if not isinstance(mission_id, str) or not 1 <= len(mission_id) <= 32 or not _SAFE_ID.fullmatch(mission_id):
            raise MissionValidationError("mission_id must contain 1 to 32 characters")
        if not isinstance(boat_id, str) or not 1 <= len(boat_id) <= 32 or not _SAFE_ID.fullmatch(boat_id):
            raise MissionValidationError("boat_id must contain 1 to 32 characters")
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80:
            raise MissionValidationError("name must contain 1 to 80 characters")
        if not isinstance(raw_waypoints, list) or not 1 <= len(raw_waypoints) <= 200:
            raise MissionValidationError("mission must contain 1 to 200 waypoints")
        if status not in {"draft", "pending", "active", "completed", "cancelled", "failed"}:
            raise MissionValidationError("invalid mission status")
        if strategy not in _MISSION_STRATEGIES:
            raise MissionValidationError("strategy must be balanced or best_time")
        throttle = _finite_number(value.get("cruise_throttle", 0.45), "cruise_throttle")
        if not 0.0 <= throttle <= 1.0:
            raise MissionValidationError("cruise_throttle must be between 0 and 1")
        try:
            waypoints = tuple(Waypoint.from_dict(item) for item in raw_waypoints)
        except (TypeError, AttributeError) as exc:
            raise MissionValidationError("each waypoint must be an object") from exc
        return cls(mission_id, boat_id, name.strip(), waypoints, throttle, status, strategy)

    def to_dict(self) -> dict[str, Any]:
        return {
            "mission_id": self.mission_id,
            "boat_id": self.boat_id,
            "name": self.name,
            "waypoints": [item.to_dict() for item in self.waypoints],
            "cruise_throttle": self.cruise_throttle,
            "strategy": self.strategy,
            "status": self.status,
        }


@dataclass(frozen=True, slots=True)
class AutopilotCommand:
    command_sequence: int
    target_pod_deg: float
    throttle_norm: float
    valid_for_ms: int
    mission_id: str
    waypoint_index: int
    drive_direction: str = "forward"
    steering_norm: float = 0.0
    stability_factor: float = 1.0
    maneuver: str = "cruise"

    def to_payload(self) -> bytes:
        if not 0 <= self.command_sequence <= 0xFFFFFFFF:
            raise ValueError("command_sequence must fit uint32")
        if not math.isfinite(self.target_pod_deg) or not 0.0 <= self.target_pod_deg <= 270.0:
            raise ValueError("target_pod_deg out of range")
        if not math.isfinite(self.throttle_norm) or not 0.0 <= self.throttle_norm <= 1.0:
            raise ValueError("throttle_norm out of range")
        if not 50 <= self.valid_for_ms <= 1000:
            raise ValueError("valid_for_ms out of range")
        if not 1 <= len(self.mission_id) <= 32:
            raise ValueError("mission_id must contain 1 to 32 characters")
        if not 0 <= self.waypoint_index <= 65535:
            raise ValueError("waypoint_index must fit uint16")
        if self.drive_direction not in _DRIVE_DIRECTIONS:
            raise ValueError("invalid drive_direction")
        if not math.isfinite(self.steering_norm) or not -1.0 <= self.steering_norm <= 1.0:
            raise ValueError("steering_norm out of range")
        if not math.isfinite(self.stability_factor) or not 0.0 <= self.stability_factor <= 1.0:
            raise ValueError("stability_factor out of range")
        if not isinstance(self.maneuver, str) or not 1 <= len(self.maneuver) <= 32:
            raise ValueError("invalid maneuver")
        return json.dumps(
            {
                "command_sequence": self.command_sequence,
                "target_pod_deg": round(self.target_pod_deg, 2),
                "throttle_norm": round(self.throttle_norm, 3),
                "valid_for_ms": self.valid_for_ms,
                "mission_id": self.mission_id,
                "waypoint_index": self.waypoint_index,
                "drive_direction": self.drive_direction,
                "steering_norm": round(self.steering_norm, 3),
                "stability_factor": round(self.stability_factor, 3),
                "maneuver": self.maneuver,
            },
            separators=(",", ":"),
        ).encode()

    def to_frame(self, monotonic_ms: int) -> bytes:
        return encode_frame(
            Frame(
                MessageType.AUTOPILOT_COMMAND,
                self.command_sequence,
                monotonic_ms & 0xFFFFFFFF,
                self.to_payload(),
            )
        )
