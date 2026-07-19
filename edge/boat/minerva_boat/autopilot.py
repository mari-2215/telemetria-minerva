from __future__ import annotations

from dataclasses import dataclass
import json
import math
import time
from typing import Any
from urllib import error, request

from minerva_protocol import AutopilotCommand, Mission, MissionValidationError, Telemetry

from .store import OutboxStore


class MissionSyncError(RuntimeError):
    pass


class HttpMissionClient:
    def __init__(self, base_url: str, device_token: str, timeout_seconds: float = 5.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.device_token = device_token
        self.timeout_seconds = timeout_seconds

    def _request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"X-Device-Token": self.device_token}
        if data is not None:
            headers["Content-Type"] = "application/json"
        operation = request.Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
        try:
            with request.urlopen(operation, timeout=self.timeout_seconds) as response:
                body = response.read()
        except (error.URLError, TimeoutError) as exc:
            raise MissionSyncError(str(exc)) from exc
        return json.loads(body) if body else None

    def pending(self, boat_id: str) -> Mission | None:
        value = self._request("GET", f"/v1/boats/{boat_id}/missions/pending")
        if value is None:
            return None
        try:
            return Mission.from_dict(value)
        except MissionValidationError as exc:
            raise MissionSyncError(f"invalid mission from server: {exc}") from exc

    def set_status(self, mission_id: str, status: str, error_message: str | None = None) -> None:
        payload: dict[str, Any] = {"status": status}
        if error_message:
            payload["error"] = error_message
        self._request("POST", f"/v1/missions/{mission_id}/status", payload)

    def upload_recording(self, boat_id: str, recording: dict[str, Any]) -> None:
        self._request("POST", f"/v1/boats/{boat_id}/recordings", recording)


@dataclass(frozen=True, slots=True)
class NavigationSolution:
    distance_m: float
    bearing_deg: float
    heading_error_deg: float
    target_pod_deg: float
    throttle_norm: float


def _wrap_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def _triangle(value: float, left: float, peak: float, right: float) -> float:
    if value <= left or value >= right:
        return 0.0
    if value == peak:
        return 1.0
    return (value - left) / (peak - left) if value < peak else (right - value) / (right - peak)


def fuzzy_navigation_output(
    heading_error_deg: float,
    distance_m: float,
    cruise_throttle: float,
    strategy: str = "balanced",
) -> tuple[float, float]:
    """Mamdani-style controller for pod deflection and propulsion power.

    ``balanced`` prioritizes smoothness and energy. ``best_time`` keeps more
    power on straights and medium turns, while still cutting power near a
    waypoint or during a very large heading error.
    """
    error = min(180.0, abs(heading_error_deg))
    heading_membership = (
        max(0.0, 1.0 - error / 25.0),
        _triangle(error, 10.0, 45.0, 90.0),
        max(0.0, min(1.0, (error - 55.0) / 45.0)),
    )
    heading_outputs = (0.0, 27.0, 45.0)
    heading_weight = sum(heading_membership) or 1.0
    deflection = sum(weight * output for weight, output in zip(heading_membership, heading_outputs)) / heading_weight
    if heading_error_deg < 0:
        deflection = -deflection

    distance_membership = (
        max(0.0, 1.0 - distance_m / 18.0),
        _triangle(distance_m, 8.0, 30.0, 70.0),
        max(0.0, min(1.0, (distance_m - 35.0) / 45.0)),
    )
    if strategy == "best_time":
        throttle_outputs = (
            min(cruise_throttle, max(0.24, cruise_throttle * 0.48)),
            cruise_throttle * 0.88,
            cruise_throttle,
        )
        turn_penalty = 0.38
    else:
        throttle_outputs = (min(0.20, cruise_throttle), cruise_throttle * 0.65, cruise_throttle)
        turn_penalty = 0.55

    distance_weight = sum(distance_membership) or 1.0
    throttle = sum(weight * output for weight, output in zip(distance_membership, throttle_outputs)) / distance_weight
    turn_reduction = 1.0 - turn_penalty * min(1.0, error / 90.0)
    throttle *= turn_reduction

    if strategy == "best_time" and distance_m > 24.0 and error < 14.0:
        throttle = max(throttle, cruise_throttle * 0.95)

    return deflection, max(0.0, min(cruise_throttle, throttle))


def navigation_solution(
    latitude_deg: float,
    longitude_deg: float,
    course_deg: float,
    target_latitude_deg: float,
    target_longitude_deg: float,
    cruise_throttle: float,
    strategy: str = "balanced",
) -> NavigationSolution:
    radius_m = 6_371_000.0
    lat1 = math.radians(latitude_deg)
    lat2 = math.radians(target_latitude_deg)
    delta_lat = lat2 - lat1
    delta_lon = math.radians(target_longitude_deg - longitude_deg)
    a = math.sin(delta_lat / 2.0) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2.0) ** 2
    distance = radius_m * 2.0 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))
    y = math.sin(delta_lon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(delta_lon)
    bearing = math.degrees(math.atan2(y, x)) % 360.0
    error_deg = _wrap_degrees(bearing - course_deg)
    rudder_deflection, throttle = fuzzy_navigation_output(error_deg, distance, cruise_throttle, strategy)
    return NavigationSolution(distance, bearing, error_deg, 45.0 + rudder_deflection, throttle)


class MissionAutopilot:
    def __init__(
        self,
        store: OutboxStore,
        boat_id: str,
        client: HttpMissionClient | None = None,
        command_interval_seconds: float = 0.2,
    ) -> None:
        self.store = store
        self.boat_id = boat_id
        self.client = client
        self.command_interval_seconds = command_interval_seconds
        self.command_sequence = 0
        self.last_command_at = 0.0
        self.last_poll_at = 0.0

    def poll_remote(self, now: float | None = None) -> bool:
        current = time.monotonic() if now is None else now
        if self.client is None or current - self.last_poll_at < 5.0:
            return False
        self.last_poll_at = current
        for recording in self.store.pending_recordings():
            self.client.upload_recording(self.boat_id, recording)
            self.store.mark_recording_uploaded(recording["mission_id"], Telemetry.utc_now())
        mission = self.client.pending(self.boat_id)
        if mission is None:
            return False
        self.store.save_mission(mission.to_dict())
        self.client.set_status(mission.mission_id, "active")
        return True

    def build_command(self, telemetry: Telemetry | None, now: float | None = None) -> bytes | None:
        current = time.monotonic() if now is None else now
        if current - self.last_command_at < self.command_interval_seconds or telemetry is None:
            return None
        control = telemetry.data.get("control") or {}
        autopilot_state = telemetry.data.get("autopilot") or {}
        if control.get("mode") != "auto" or not control.get("rc_healthy", False):
            return None
        if not autopilot_state.get("latched", False):
            return None
        position = telemetry.data.get("position") or {}
        if "latitude_deg" not in position or "longitude_deg" not in position:
            return None
        raw = self.store.active_mission(self.boat_id)
        if raw is None:
            return None
        mission = Mission.from_dict(raw)
        index = int(raw.get("waypoint_index", 0))
        if index >= len(mission.waypoints):
            return None
        waypoint = mission.waypoints[index]
        solution = navigation_solution(
            float(position["latitude_deg"]),
            float(position["longitude_deg"]),
            float(position.get("course_deg", 0.0)),
            waypoint.latitude_deg,
            waypoint.longitude_deg,
            mission.cruise_throttle,
            mission.strategy,
        )
        completed = False
        while solution.distance_m <= waypoint.tolerance_m:
            index += 1
            self.store.set_mission_progress(mission.mission_id, index)
            if index >= len(mission.waypoints):
                completed = True
                break
            waypoint = mission.waypoints[index]
            solution = navigation_solution(
                float(position["latitude_deg"]),
                float(position["longitude_deg"]),
                float(position.get("course_deg", 0.0)),
                waypoint.latitude_deg,
                waypoint.longitude_deg,
                mission.cruise_throttle,
                mission.strategy,
            )
        self.command_sequence = (self.command_sequence + 1) & 0xFFFFFFFF
        command = AutopilotCommand(
            command_sequence=self.command_sequence,
            target_pod_deg=45.0 if completed else solution.target_pod_deg,
            throttle_norm=0.0 if completed else solution.throttle_norm,
            valid_for_ms=500,
            mission_id=mission.mission_id,
            waypoint_index=max(0, min(index, len(mission.waypoints) - 1)),
        )
        self.last_command_at = current
        if completed:
            self.store.finish_mission(mission.mission_id)
            if self.client is not None:
                self.client.set_status(mission.mission_id, "completed")
        return command.to_frame(int(current * 1000.0))
