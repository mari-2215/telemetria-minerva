from __future__ import annotations

from dataclasses import dataclass, replace
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
        value = self._request("GET", f"/v1/boats/{boat_id}/missions/authorized")
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

    def set_ready(self, mission_id: str, ready: bool) -> None:
        self._request("POST", f"/v1/missions/{mission_id}/ready/device", {"ready": ready})

    def upload_recording(self, boat_id: str, recording: dict[str, Any]) -> None:
        self._request("POST", f"/v1/boats/{boat_id}/recordings", recording)


@dataclass(frozen=True, slots=True)
class NavigationSolution:
    distance_m: float
    bearing_deg: float
    heading_error_deg: float
    target_pod_deg: float
    throttle_norm: float
    drive_direction: str = "forward"
    steering_norm: float = 0.0
    stability_factor: float = 1.0
    maneuver: str = "cruise"


@dataclass(frozen=True, slots=True)
class StabilityAssessment:
    factor: float
    roll_deg: float
    pitch_deg: float
    lateral_dynamic_mps2: float
    dynamic_accel_mps2: float
    state: str


def _wrap_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def _triangle(value: float, left: float, peak: float, right: float) -> float:
    if value <= left or value >= right:
        return 0.0
    if value == peak:
        return 1.0
    return (value - left) / (peak - left) if value < peak else (right - value) / (right - peak)


def _finite_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def vessel_kind(boat_id: str, telemetry: Telemetry | None = None) -> str:
    if telemetry is not None:
        vessel = telemetry.data.get("vessel") or {}
        explicit = vessel.get("type") if isinstance(vessel, dict) else None
        if isinstance(explicit, str):
            normalized = explicit.strip().lower()
            if normalized in {"netuno", "rudder", "conventional", "leme"}:
                return "rudder"
            if normalized in {"azimutal", "azimuth", "azimuthal", "pod"}:
                return "azimuth"
    return "rudder" if boat_id.lower().startswith("netuno") else "azimuth"


def fuzzy_navigation_output(
    heading_error_deg: float,
    distance_m: float,
    cruise_throttle: float,
    strategy: str = "balanced",
) -> tuple[float, float]:
    """Mamdani-style controller for steering deflection and propulsion power."""

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
        throttle_outputs = (
            min(0.20, cruise_throttle),
            cruise_throttle * 0.65,
            cruise_throttle,
        )
        turn_penalty = 0.55

    distance_weight = sum(distance_membership) or 1.0
    throttle = sum(weight * output for weight, output in zip(distance_membership, throttle_outputs)) / distance_weight
    throttle *= 1.0 - turn_penalty * min(1.0, error / 90.0)

    if strategy == "best_time" and distance_m > 24.0 and error < 14.0:
        throttle = max(throttle, cruise_throttle * 0.95)

    return deflection, max(0.0, min(cruise_throttle, throttle))


def _distance_and_bearing(
    latitude_deg: float,
    longitude_deg: float,
    target_latitude_deg: float,
    target_longitude_deg: float,
) -> tuple[float, float]:
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
    return distance, bearing


def navigation_solution(
    latitude_deg: float,
    longitude_deg: float,
    course_deg: float,
    target_latitude_deg: float,
    target_longitude_deg: float,
    cruise_throttle: float,
    strategy: str = "balanced",
) -> NavigationSolution:
    distance, bearing = _distance_and_bearing(
        latitude_deg,
        longitude_deg,
        target_latitude_deg,
        target_longitude_deg,
    )
    error_deg = _wrap_degrees(bearing - course_deg)
    rudder_deflection, throttle = fuzzy_navigation_output(error_deg, distance, cruise_throttle, strategy)
    return NavigationSolution(
        distance,
        bearing,
        error_deg,
        45.0 + rudder_deflection,
        throttle,
        steering_norm=max(-1.0, min(1.0, rudder_deflection / 45.0)),
    )


def azimuth_navigation_solution(
    latitude_deg: float,
    longitude_deg: float,
    hull_heading_deg: float,
    target_latitude_deg: float,
    target_longitude_deg: float,
    cruise_throttle: float,
    strategy: str = "balanced",
    current_pod_deg: float = 45.0,
) -> NavigationSolution:
    distance, bearing = _distance_and_bearing(
        latitude_deg,
        longitude_deg,
        target_latitude_deg,
        target_longitude_deg,
    )
    error_deg = _wrap_degrees(bearing - hull_heading_deg)
    direct_pod = (45.0 + error_deg) % 360.0

    if direct_pod <= 270.0:
        _, throttle = fuzzy_navigation_output(0.0, distance, cruise_throttle, strategy)
        pod_alignment_error = abs(_wrap_degrees(direct_pod - current_pod_deg))
        if pod_alignment_error >= 32.0:
            throttle = 0.0
        elif pod_alignment_error > 7.0:
            throttle *= (32.0 - pod_alignment_error) / 25.0
        maneuver = "reverse_pod" if abs(error_deg) >= 135.0 else "vector_pod"
        return NavigationSolution(
            distance,
            bearing,
            error_deg,
            direct_pod,
            max(0.0, throttle),
            drive_direction="forward",
            steering_norm=max(-1.0, min(1.0, error_deg / 180.0)),
            maneuver=maneuver,
        )

    deflection, throttle = fuzzy_navigation_output(error_deg, distance, cruise_throttle, strategy)
    target_pod = max(0.0, min(270.0, 45.0 + deflection))
    return NavigationSolution(
        distance,
        bearing,
        error_deg,
        target_pod,
        throttle,
        drive_direction="forward",
        steering_norm=max(-1.0, min(1.0, deflection / 45.0)),
        maneuver="turn_hull",
    )


def netuno_navigation_solution(
    latitude_deg: float,
    longitude_deg: float,
    hull_heading_deg: float,
    target_latitude_deg: float,
    target_longitude_deg: float,
    cruise_throttle: float,
    strategy: str = "balanced",
    current_direction: str = "forward",
) -> NavigationSolution:
    distance, bearing = _distance_and_bearing(
        latitude_deg,
        longitude_deg,
        target_latitude_deg,
        target_longitude_deg,
    )
    forward_error = _wrap_degrees(bearing - hull_heading_deg)
    reverse_error = _wrap_degrees(bearing - (hull_heading_deg + 180.0))

    if current_direction == "reverse":
        use_reverse = not (
            abs(reverse_error) > 105.0
            and abs(forward_error) + 20.0 < abs(reverse_error)
        )
    else:
        use_reverse = (
            abs(forward_error) >= 112.0
            and abs(reverse_error) + 18.0 < abs(forward_error)
        )

    effective_error = reverse_error if use_reverse else forward_error
    deflection, throttle = fuzzy_navigation_output(
        effective_error,
        distance,
        cruise_throttle,
        strategy,
    )
    steering = max(-1.0, min(1.0, deflection / 45.0))
    if use_reverse:
        steering = -steering

    return NavigationSolution(
        distance,
        bearing,
        forward_error,
        45.0 + steering * 45.0,
        throttle,
        drive_direction="reverse" if use_reverse else "forward",
        steering_norm=steering,
        maneuver="reverse" if use_reverse else "forward",
    )


def _axis_factor(value: float, good: float, severe: float, stop: float) -> float:
    value = abs(value)
    if value <= good:
        return 1.0
    if value >= stop:
        return 0.0
    if value <= severe:
        return 1.0 - (value - good) / (severe - good) * 0.55
    return 0.45 - (value - severe) / (stop - severe) * 0.45


def assess_stability(motion: dict[str, Any] | None) -> StabilityAssessment:
    if not motion:
        return StabilityAssessment(1.0, 0.0, 0.0, 0.0, 0.0, "unknown")

    ax = _finite_number(motion.get("accel_x_mps2"))
    ay = _finite_number(motion.get("accel_y_mps2"))
    az = _finite_number(motion.get("accel_z_mps2"))
    roll = _finite_number(motion.get("roll_deg"))
    pitch = _finite_number(motion.get("pitch_deg"))

    if roll is None and ay is not None and az is not None:
        roll = math.degrees(math.atan2(ay, az))
    if pitch is None and ax is not None and ay is not None and az is not None:
        pitch = math.degrees(math.atan2(-ax, math.sqrt(ay * ay + az * az)))

    roll = roll or 0.0
    pitch = pitch or 0.0
    gravity = 9.80665
    magnitude = math.sqrt(ax * ax + ay * ay + az * az) if ax is not None and ay is not None and az is not None else gravity
    dynamic = abs(magnitude - gravity)
    expected_lateral = gravity * math.sin(math.radians(roll))
    lateral_dynamic = abs((ay or 0.0) - expected_lateral)

    factor = min(
        _axis_factor(roll, 8.0, 18.0, 28.0),
        _axis_factor(pitch, 6.0, 14.0, 22.0),
        _axis_factor(lateral_dynamic, 1.5, 4.0, 7.0),
        _axis_factor(dynamic, 1.5, 4.0, 7.0),
    )
    state = "stable" if factor >= 0.85 else "reduced" if factor > 0.0 else "stop"
    return StabilityAssessment(
        max(0.0, min(1.0, factor)),
        roll,
        pitch,
        lateral_dynamic,
        dynamic,
        state,
    )


def apply_stability_limit(
    solution: NavigationSolution,
    assessment: StabilityAssessment,
) -> NavigationSolution:
    factor = assessment.factor
    steering = solution.steering_norm
    target_pod = solution.target_pod_deg
    if factor < 0.65 and solution.drive_direction in {"forward", "reverse"} and solution.maneuver not in {"reverse_pod", "vector_pod"}:
        steering *= max(0.35, factor)
        target_pod = 45.0 + steering * 45.0

    return replace(
        solution,
        target_pod_deg=max(0.0, min(270.0, target_pod)),
        throttle_norm=max(0.0, min(1.0, solution.throttle_norm * factor)),
        steering_norm=max(-1.0, min(1.0, steering)),
        stability_factor=factor,
        maneuver="stability_stop" if factor == 0.0 else solution.maneuver,
    )


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
        self.drive_direction = "forward"
        self.pending_drive_direction: str | None = None
        self.direction_change_started_at = 0.0
        self.filtered_stability_factor = 1.0
        self.estimated_hull_heading_deg: float | None = None

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

    def _revoke_if_active(self) -> None:
        mission_id = self.store.revoke_active_mission(self.boat_id)
        self.pending_drive_direction = None
        if mission_id is None or self.client is None:
            return
        try:
            self.client.set_ready(mission_id, False)
            self.client.set_status(mission_id, "pending")
        except MissionSyncError:
            pass

    def _estimate_hull_heading(
        self,
        telemetry: Telemetry,
        kind: str,
        current_pod_deg: float,
    ) -> float:
        motion = telemetry.data.get("motion") or {}
        yaw = _finite_number(motion.get("yaw_deg")) if isinstance(motion, dict) else None
        if yaw is not None:
            self.estimated_hull_heading_deg = yaw % 360.0
            return self.estimated_hull_heading_deg

        position = telemetry.data.get("position") or {}
        course = _finite_number(position.get("course_deg"))
        speed = _finite_number(position.get("speed_mps")) or 0.0
        if course is not None and speed > 0.20:
            if kind == "azimuth":
                estimate = course - (current_pod_deg - 45.0)
            elif self.drive_direction == "reverse":
                estimate = course - 180.0
            else:
                estimate = course
            self.estimated_hull_heading_deg = estimate % 360.0
        elif self.estimated_hull_heading_deg is None:
            self.estimated_hull_heading_deg = (course or 0.0) % 360.0
        return self.estimated_hull_heading_deg

    def _direction_interlock(
        self,
        desired: str,
        throttle: float,
        current: float,
    ) -> tuple[str, float]:
        if desired == self.drive_direction:
            self.pending_drive_direction = None
            return desired, throttle

        if self.pending_drive_direction != desired:
            self.pending_drive_direction = desired
            self.direction_change_started_at = current
            return "stop", 0.0

        if current - self.direction_change_started_at < 0.85:
            return "stop", 0.0

        self.drive_direction = desired
        self.pending_drive_direction = None
        return desired, throttle

    def _solve(
        self,
        telemetry: Telemetry,
        mission: Mission,
        waypoint_index: int,
        current: float,
    ) -> NavigationSolution:
        position = telemetry.data.get("position") or {}
        propulsion = telemetry.data.get("propulsion") or {}
        current_pod = _finite_number(propulsion.get("pod_angle_deg")) or 45.0
        kind = vessel_kind(self.boat_id, telemetry)
        heading = self._estimate_hull_heading(telemetry, kind, current_pod)
        waypoint = mission.waypoints[waypoint_index]

        if kind == "rudder":
            solution = netuno_navigation_solution(
                float(position["latitude_deg"]),
                float(position["longitude_deg"]),
                heading,
                waypoint.latitude_deg,
                waypoint.longitude_deg,
                mission.cruise_throttle,
                mission.strategy,
                self.drive_direction,
            )
            direction, throttle = self._direction_interlock(
                solution.drive_direction,
                solution.throttle_norm,
                current,
            )
            solution = replace(
                solution,
                drive_direction=direction,
                throttle_norm=throttle,
                maneuver="direction_change" if direction == "stop" else solution.maneuver,
            )
        else:
            solution = azimuth_navigation_solution(
                float(position["latitude_deg"]),
                float(position["longitude_deg"]),
                heading,
                waypoint.latitude_deg,
                waypoint.longitude_deg,
                mission.cruise_throttle,
                mission.strategy,
                current_pod,
            )

        motion = telemetry.data.get("motion") or {}
        assessment = assess_stability(motion if isinstance(motion, dict) else {})
        if assessment.factor == 0.0:
            self.filtered_stability_factor = 0.0
        else:
            self.filtered_stability_factor = (
                0.75 * self.filtered_stability_factor + 0.25 * assessment.factor
            )
        filtered = replace(assessment, factor=self.filtered_stability_factor)
        return apply_stability_limit(solution, filtered)

    def build_command(self, telemetry: Telemetry | None, now: float | None = None) -> bytes | None:
        current = time.monotonic() if now is None else now
        if current - self.last_command_at < self.command_interval_seconds or telemetry is None:
            return None

        control = telemetry.data.get("control") or {}
        autopilot_state = telemetry.data.get("autopilot") or {}
        ready_for_auto = (
            control.get("mode") == "auto"
            and bool(control.get("rc_healthy", False))
            and bool(autopilot_state.get("latched", False))
        )
        if not ready_for_auto:
            self._revoke_if_active()
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

        solution = self._solve(telemetry, mission, index, current)
        completed = False
        while solution.distance_m <= mission.waypoints[index].tolerance_m:
            index += 1
            self.store.set_mission_progress(mission.mission_id, index)
            if index >= len(mission.waypoints):
                completed = True
                break
            solution = self._solve(telemetry, mission, index, current)

        self.command_sequence = (self.command_sequence + 1) & 0xFFFFFFFF
        command = AutopilotCommand(
            command_sequence=self.command_sequence,
            target_pod_deg=45.0 if completed else solution.target_pod_deg,
            throttle_norm=0.0 if completed else solution.throttle_norm,
            valid_for_ms=500,
            mission_id=mission.mission_id,
            waypoint_index=max(0, min(index, len(mission.waypoints) - 1)),
            drive_direction="stop" if completed else solution.drive_direction,
            steering_norm=0.0 if completed else solution.steering_norm,
            stability_factor=solution.stability_factor,
            maneuver="completed" if completed else solution.maneuver,
        )
        self.last_command_at = current
        if completed:
            self.store.finish_mission(mission.mission_id)
            if self.client is not None:
                self.client.set_status(mission.mission_id, "completed")
        return command.to_frame(int(current * 1000.0))
