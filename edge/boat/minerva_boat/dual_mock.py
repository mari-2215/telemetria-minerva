from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import math
import os
import queue
import sys
import threading
import time
from typing import Any
from urllib import error, request

from .autopilot import (
    apply_stability_limit,
    assess_stability,
    azimuth_navigation_solution,
    netuno_navigation_solution,
)


EARTH_RADIUS_M = 6_371_000.0


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _wrap_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def _approach(current: float, target: float, step: float) -> float:
    delta = target - current
    if abs(delta) <= step:
        return target
    return current + math.copysign(step, delta)


def _move(latitude: float, longitude: float, bearing_deg: float, distance_m: float) -> tuple[float, float]:
    angular = distance_m / EARTH_RADIUS_M
    bearing = math.radians(bearing_deg)
    lat1 = math.radians(latitude)
    lon1 = math.radians(longitude)
    lat2 = math.asin(
        math.sin(lat1) * math.cos(angular)
        + math.cos(lat1) * math.sin(angular) * math.cos(bearing)
    )
    lon2 = lon1 + math.atan2(
        math.sin(bearing) * math.sin(angular) * math.cos(lat1),
        math.cos(angular) - math.sin(lat1) * math.sin(lat2),
    )
    return math.degrees(lat2), math.degrees(lon2)


def _distance(latitude: float, longitude: float, target_latitude: float, target_longitude: float) -> float:
    lat1 = math.radians(latitude)
    lat2 = math.radians(target_latitude)
    delta_lat = lat2 - lat1
    delta_lon = math.radians(target_longitude - longitude)
    a = (
        math.sin(delta_lat / 2.0) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2.0) ** 2
    )
    return EARTH_RADIUS_M * 2.0 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


class MockApi:
    def __init__(self, base_url: str, device_token: str, timeout: float = 2.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.device_token = device_token
        self.timeout = timeout

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        body = json.dumps(payload, separators=(",", ":")).encode() if payload is not None else None
        headers = {"X-Device-Token": self.device_token}
        if body is not None:
            headers["Content-Type"] = "application/json"
        operation = request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with request.urlopen(operation, timeout=self.timeout) as response:
                raw = response.read()
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", "replace")
            raise RuntimeError(f"{method} {path}: HTTP {exc.code}: {details}") from exc
        except (error.URLError, TimeoutError) as exc:
            raise RuntimeError(f"{method} {path}: {exc}") from exc
        return json.loads(raw) if raw else None

    def ingest(self, payload: dict[str, Any]) -> None:
        self.request("POST", "/v1/ingest", payload)

    def authorized_mission(self, boat_id: str) -> dict[str, Any] | None:
        value = self.request("GET", f"/v1/boats/{boat_id}/missions/authorized")
        return value if isinstance(value, dict) else None

    def set_status(self, mission_id: str, status: str) -> None:
        self.request("POST", f"/v1/missions/{mission_id}/status", {"status": status})


@dataclass
class SimBoat:
    boat_id: str
    kind: str
    latitude: float
    longitude: float
    hull_heading_deg: float
    sequence: int = 0
    mode: str = "auto"
    latch: bool = False
    rc_healthy: bool = True
    wave_level: float = 0.65
    pod_deg: float = 45.0
    target_pod_deg: float = 45.0
    rudder_norm: float = 0.0
    throttle_norm: float = 0.0
    drive_direction: str = "forward"
    pending_direction: str | None = None
    direction_change_started_at: float = 0.0
    course_deg: float = 0.0
    speed_mps: float = 0.0
    mission: dict[str, Any] | None = None
    waypoint_index: int = 0
    mission_status_sent: bool = False
    completed_mission_id: str | None = None
    last_poll_at: float = 0.0
    last_error: str | None = None
    command_maneuver: str = "idle"
    stability_factor: float = 1.0
    _phase_offset: float = field(default=0.0)

    def _motion(self, now: float) -> dict[str, float]:
        phase = now * 1.35 + self._phase_offset
        turn_load = abs(self.rudder_norm) * self.speed_mps * 1.25
        roll = math.sin(phase) * (3.5 + self.wave_level * 5.0) + self.rudder_norm * 4.0
        pitch = math.cos(phase * 0.73) * (2.0 + self.wave_level * 3.5)
        lateral_dynamic = math.sin(phase * 2.1) * self.wave_level * 0.75 + turn_load
        vertical_dynamic = math.cos(phase * 1.8) * self.wave_level * 0.45
        gravity = 9.80665
        ax = -gravity * math.sin(math.radians(pitch))
        ay = gravity * math.sin(math.radians(roll)) + lateral_dynamic
        az = gravity * math.cos(math.radians(roll)) * math.cos(math.radians(pitch)) + vertical_dynamic
        return {
            "accel_x_mps2": ax,
            "accel_y_mps2": ay,
            "accel_z_mps2": az,
            "roll_deg": roll,
            "pitch_deg": pitch,
            "yaw_deg": self.hull_heading_deg % 360.0,
        }

    def poll_mission(self, api: MockApi, now: float) -> None:
        if not self.latch or self.mode != "auto" or self.mission is not None:
            return
        if now - self.last_poll_at < 1.0:
            return
        self.last_poll_at = now
        try:
            mission = api.authorized_mission(self.boat_id)
        except RuntimeError as exc:
            self.last_error = str(exc)
            return
        if mission is None:
            return
        self.mission = mission
        self.waypoint_index = 0
        self.mission_status_sent = False
        self.completed_mission_id = None
        self.last_error = None

    def _direction_interlock(self, desired: str, now: float) -> tuple[str, float]:
        if desired == self.drive_direction:
            self.pending_direction = None
            return desired, 1.0
        if self.pending_direction != desired:
            self.pending_direction = desired
            self.direction_change_started_at = now
            return "stop", 0.0
        if now - self.direction_change_started_at < 0.85:
            return "stop", 0.0
        self.drive_direction = desired
        self.pending_direction = None
        return desired, 1.0

    def update(self, api: MockApi, now: float, dt: float) -> None:
        self.poll_mission(api, now)
        motion = self._motion(now)
        assessment = assess_stability(motion)
        self.stability_factor = assessment.factor

        if self.mode != "auto" or not self.latch or self.mission is None:
            self.throttle_norm = _approach(self.throttle_norm, 0.0, dt * 1.8)
            self.speed_mps = _approach(self.speed_mps, 0.0, dt * 2.5)
            self.command_maneuver = "idle"
            return

        if not self.mission_status_sent:
            try:
                api.set_status(str(self.mission["mission_id"]), "active")
                self.mission_status_sent = True
            except RuntimeError as exc:
                self.last_error = str(exc)

        waypoints = self.mission.get("waypoints") or []
        if self.waypoint_index >= len(waypoints):
            self._complete(api)
            return

        waypoint = waypoints[self.waypoint_index]
        target_lat = float(waypoint["latitude_deg"])
        target_lon = float(waypoint["longitude_deg"])
        tolerance = float(waypoint.get("tolerance_m", 6.0))
        distance = _distance(self.latitude, self.longitude, target_lat, target_lon)
        if distance <= tolerance:
            self.waypoint_index += 1
            if self.waypoint_index >= len(waypoints):
                self._complete(api)
                return
            waypoint = waypoints[self.waypoint_index]
            target_lat = float(waypoint["latitude_deg"])
            target_lon = float(waypoint["longitude_deg"])

        cruise = float(self.mission.get("cruise_throttle", 0.55))
        strategy = str(self.mission.get("strategy", "balanced"))

        if self.kind == "azimuth":
            solution = azimuth_navigation_solution(
                self.latitude,
                self.longitude,
                self.hull_heading_deg,
                target_lat,
                target_lon,
                cruise,
                strategy,
                self.pod_deg,
            )
            solution = apply_stability_limit(solution, assessment)
            self.target_pod_deg = solution.target_pod_deg
            self.pod_deg = _approach(self.pod_deg, self.target_pod_deg, dt * 105.0)
            self.rudder_norm = solution.steering_norm
            desired_throttle = solution.throttle_norm
            self.drive_direction = "forward"
            movement_bearing = (
                self.hull_heading_deg + (self.pod_deg - 45.0)
            ) % 360.0
            self.hull_heading_deg = (
                self.hull_heading_deg
                + self.rudder_norm * desired_throttle * 5.0 * dt
            ) % 360.0
        else:
            solution = netuno_navigation_solution(
                self.latitude,
                self.longitude,
                self.hull_heading_deg,
                target_lat,
                target_lon,
                cruise,
                strategy,
                self.drive_direction,
            )
            solution = apply_stability_limit(solution, assessment)
            direction, direction_factor = self._direction_interlock(
                solution.drive_direction,
                now,
            )
            self.rudder_norm = _approach(
                self.rudder_norm,
                solution.steering_norm,
                dt * 2.2,
            )
            desired_throttle = solution.throttle_norm * direction_factor
            if direction == "stop":
                movement_bearing = self.course_deg
            else:
                self.drive_direction = direction
                movement_bearing = (
                    self.hull_heading_deg
                    + (180.0 if self.drive_direction == "reverse" else 0.0)
                ) % 360.0
                velocity_sign = -1.0 if self.drive_direction == "reverse" else 1.0
                self.hull_heading_deg = (
                    self.hull_heading_deg
                    + self.rudder_norm
                    * velocity_sign
                    * max(self.speed_mps, 0.25)
                    * 30.0
                    * dt
                ) % 360.0
            self.target_pod_deg = 45.0 + self.rudder_norm * 45.0

        self.command_maneuver = solution.maneuver
        self.throttle_norm = _approach(
            self.throttle_norm,
            desired_throttle,
            dt * 0.85,
        )
        target_speed = self.throttle_norm * (2.5 if strategy == "best_time" else 2.0)
        self.speed_mps = _approach(self.speed_mps, target_speed, dt * 1.4)
        if self.speed_mps > 0.01 and desired_throttle > 0.0:
            self.latitude, self.longitude = _move(
                self.latitude,
                self.longitude,
                movement_bearing,
                self.speed_mps * dt,
            )
            self.course_deg = movement_bearing

    def _complete(self, api: MockApi) -> None:
        mission = self.mission
        self.throttle_norm = 0.0
        self.speed_mps = 0.0
        self.command_maneuver = "completed"
        if mission is not None:
            mission_id = str(mission["mission_id"])
            if self.completed_mission_id != mission_id:
                try:
                    api.set_status(mission_id, "completed")
                except RuntimeError as exc:
                    self.last_error = str(exc)
                self.completed_mission_id = mission_id
        self.mission = None
        self.waypoint_index = 0
        self.mission_status_sent = False

    def telemetry(self, now: float) -> dict[str, Any]:
        motion = self._motion(now)
        motor_on = self.throttle_norm > 0.02
        if self.kind == "rudder":
            if not motor_on:
                esc_pwm = 1500
            elif self.drive_direction == "reverse":
                esc_pwm = round(1500 - self.throttle_norm * 400)
            else:
                esc_pwm = round(1500 + self.throttle_norm * 400)
        else:
            esc_pwm = round(1000 + self.throttle_norm * 1000)

        mission_id = "" if self.mission is None else str(self.mission["mission_id"])
        alarms: list[str] = []
        if self.stability_factor == 0.0:
            alarms.append("STABILITY_STOP")
        elif self.stability_factor < 0.65:
            alarms.append("STABILITY_POWER_REDUCED")

        payload = {
            "schema_version": 1,
            "boat_id": self.boat_id,
            "sequence": self.sequence,
            "recorded_at": _utc_now(),
            "vessel": {
                "type": self.kind,
                "display_name": "Azimutal" if self.kind == "azimuth" else "Netuno",
            },
            "position": {
                "latitude_deg": self.latitude,
                "longitude_deg": self.longitude,
                "speed_mps": self.speed_mps,
                "course_deg": self.course_deg % 360.0,
                "fix": 3,
                "hdop": 0.8,
            },
            "power": {
                "battery_v": 12.55 if self.kind == "azimuth" else 12.32,
                "current_a": 0.8 + self.throttle_norm * 8.0,
            },
            "motion": motion,
            "environment": {
                "electronics_temp_c": 32.0 + self.throttle_norm * 5.0,
                "humidity_pct": 53.0,
                "water_detected": False,
            },
            "control": {
                "mode": self.mode,
                "recording_active": False,
                "rc_healthy": self.rc_healthy,
                "failsafe_active": not self.rc_healthy,
            },
            "autopilot": {
                "armed": self.mode == "auto",
                "latched": self.latch,
                "enabled": self.mode == "auto" and self.latch,
                "command_fresh": self.mission is not None,
                "last_command_sequence": self.sequence,
                "command_age_ms": 0,
                "target_pod_deg": self.target_pod_deg,
                "mission_id": mission_id,
                "waypoint_index": self.waypoint_index,
                "stability_factor": self.stability_factor,
                "maneuver": self.command_maneuver,
            },
            "propulsion": {
                "pod_angle_deg": self.pod_deg if self.kind == "azimuth" else 45.0,
                "target_pod_angle_deg": self.target_pod_deg,
                "rudder_norm": self.rudder_norm,
                "throttle_norm": self.throttle_norm,
                "drive_direction": self.drive_direction if motor_on else "stop",
                "esc_pwm_us": esc_pwm,
                "motor_on": motor_on,
            },
            "status": {
                "severity": "warning" if alarms else "ok",
                "alarms": alarms,
            },
        }
        self.sequence += 1
        return payload

    def short_status(self) -> str:
        mission = "sem rota" if self.mission is None else f"{self.mission['name']} · WP {self.waypoint_index + 1}"
        return (
            f"{self.boat_id:<13} "
            f"{self.kind:<7} "
            f"latch={'ON' if self.latch else 'OFF':<3} "
            f"{self.drive_direction:<7} "
            f"pot={self.throttle_norm * 100:5.1f}% "
            f"estab={self.stability_factor * 100:5.1f}% "
            f"{mission}"
        )


def _input_worker(commands: queue.Queue[str]) -> None:
    while True:
        line = sys.stdin.readline()
        if not line:
            commands.put("quit")
            return
        commands.put(line.strip())


def _resolve_boats(token: str, boats: dict[str, SimBoat]) -> list[SimBoat]:
    normalized = token.strip().lower()
    if normalized in {"all", "todos", "ambos"}:
        return list(boats.values())
    aliases = {
        "a": "azimutal-01",
        "azimutal": "azimutal-01",
        "n": "netuno-01",
        "netuno": "netuno-01",
    }
    boat_id = aliases.get(normalized, normalized)
    boat = boats.get(boat_id)
    if boat is None:
        raise ValueError(f"barco desconhecido: {token}")
    return [boat]


def _handle_command(command: str, boats: dict[str, SimBoat]) -> bool:
    if not command:
        return True
    parts = command.split()
    action = parts[0].lower()

    if action in {"quit", "exit", "sair"}:
        return False
    if action in {"help", "ajuda", "?"}:
        print(
            "\nComandos:\n"
            "  latch azimutal|netuno|all   alterna o latch\n"
            "  latch azimutal on|off       define o latch\n"
            "  mode azimutal auto|manual   muda o modo RC\n"
            "  waves 0.0..2.0              intensidade das ondas/ADXL\n"
            "  status                       mostra os dois barcos\n"
            "  quit                         encerra\n"
        )
        return True
    if action == "status":
        print()
        for boat in boats.values():
            print(boat.short_status())
        print()
        return True
    if action == "waves":
        if len(parts) != 2:
            raise ValueError("uso: waves 0.0..2.0")
        level = max(0.0, min(2.0, float(parts[1])))
        for boat in boats.values():
            boat.wave_level = level
        print(f"Ondas/ADXL ajustados para {level:.2f}.")
        return True
    if action == "latch":
        if len(parts) < 2:
            raise ValueError("uso: latch azimutal|netuno|all [on|off]")
        selected = _resolve_boats(parts[1], boats)
        explicit = parts[2].lower() if len(parts) >= 3 else None
        for boat in selected:
            boat.latch = (
                explicit in {"on", "1", "true", "ligado"}
                if explicit is not None
                else not boat.latch
            )
            if not boat.latch:
                boat.mission = None
                boat.throttle_norm = 0.0
                boat.speed_mps = 0.0
            print(f"{boat.boat_id}: latch {'ON' if boat.latch else 'OFF'}")
        return True
    if action == "mode":
        if len(parts) != 3 or parts[2] not in {"auto", "manual"}:
            raise ValueError("uso: mode azimutal|netuno|all auto|manual")
        for boat in _resolve_boats(parts[1], boats):
            boat.mode = parts[2]
            if boat.mode != "auto":
                boat.latch = False
                boat.mission = None
            print(f"{boat.boat_id}: modo {boat.mode.upper()}")
        return True

    raise ValueError(f"comando desconhecido: {action}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Mock interativo com Azimutal e Netuno no mesmo backend",
    )
    parser.add_argument("--api-url", default=os.getenv("MINERVA_API_URL", "http://127.0.0.1:8080"))
    parser.add_argument("--device-token", default=os.getenv("MINERVA_DEVICE_TOKEN", "dev-device-token"))
    parser.add_argument("--rate", type=float, default=5.0)
    parser.add_argument("--no-input", action="store_true", help="desativa comandos interativos")
    parser.add_argument("--count", type=int, default=0, help="0 executa continuamente")
    args = parser.parse_args()

    if args.rate <= 0:
        parser.error("--rate deve ser maior que zero")

    api = MockApi(args.api_url, args.device_token)
    boats = {
        "azimutal-01": SimBoat(
            "azimutal-01",
            "azimuth",
            -26.30440,
            -48.84640,
            0.0,
            _phase_offset=0.0,
        ),
        "netuno-01": SimBoat(
            "netuno-01",
            "rudder",
            -26.30485,
            -48.84575,
            20.0,
            _phase_offset=1.7,
        ),
    }

    commands: queue.Queue[str] = queue.Queue()
    if not args.no_input:
        threading.Thread(target=_input_worker, args=(commands,), daemon=True).start()

    print(
        "\nMOCK MINERVA · DOIS BARCOS\n"
        f"API: {args.api_url}\n"
        "Azimutal e Netuno iniciaram em AUTO com latch OFF.\n"
        "Crie/envie uma rota no app e use `latch azimutal` ou `latch netuno`.\n"
        "Digite `help` para ver todos os comandos.\n"
    )

    interval = 1.0 / args.rate
    last = time.monotonic()
    next_tick = last
    sent = 0
    running = True

    while running and (args.count == 0 or sent < args.count):
        now = time.monotonic()
        while True:
            try:
                command = commands.get_nowait()
            except queue.Empty:
                break
            try:
                running = _handle_command(command, boats)
            except (ValueError, RuntimeError) as exc:
                print(f"ERRO: {exc}")
            if not running:
                break
        if not running:
            break

        if now < next_tick:
            time.sleep(min(0.05, next_tick - now))
            continue

        dt = max(0.001, min(0.5, now - last))
        last = now
        next_tick += interval

        for boat in boats.values():
            boat.update(api, now, dt)
            try:
                api.ingest(boat.telemetry(now))
                boat.last_error = None
            except RuntimeError as exc:
                boat.last_error = str(exc)
                print(f"\rFalha em {boat.boat_id}: {exc}", file=sys.stderr)
        sent += 1

        if sent % max(1, round(args.rate * 5)) == 0:
            print()
            for boat in boats.values():
                print(boat.short_status())
            print()

    print("Mock encerrado.")


if __name__ == "__main__":
    main()
