import json
import math

from minerva_boat.autopilot import (
    apply_stability_limit,
    assess_stability,
    azimuth_navigation_solution,
    netuno_navigation_solution,
)
from minerva_protocol import AutopilotCommand, FrameDecoder


def test_azimuthal_return_rotates_pod_before_applying_power() -> None:
    turning = azimuth_navigation_solution(
        -22.8,
        -43.2,
        0.0,
        -22.801,
        -43.2,
        0.8,
        "best_time",
        current_pod_deg=45.0,
    )
    assert math.isclose(turning.target_pod_deg, 225.0, abs_tol=1.0)
    assert turning.throttle_norm == 0.0
    assert turning.maneuver == "reverse_pod"

    aligned = azimuth_navigation_solution(
        -22.8,
        -43.2,
        0.0,
        -22.801,
        -43.2,
        0.8,
        "best_time",
        current_pod_deg=225.0,
    )
    assert aligned.throttle_norm > 0.7


def test_netuno_uses_reverse_for_target_behind_without_turning_hull() -> None:
    solution = netuno_navigation_solution(
        -22.8,
        -43.2,
        0.0,
        -22.801,
        -43.2,
        0.7,
        "balanced",
        current_direction="forward",
    )
    assert solution.drive_direction == "reverse"
    assert abs(solution.steering_norm) < 0.05
    assert solution.throttle_norm > 0.0


def test_adxl_stability_reduces_and_stops_power() -> None:
    stable = assess_stability(
        {
            "accel_x_mps2": 0.0,
            "accel_y_mps2": 0.0,
            "accel_z_mps2": 9.80665,
        }
    )
    assert stable.factor == 1.0

    moderate_roll = 15.0
    moderate = assess_stability(
        {
            "roll_deg": moderate_roll,
            "pitch_deg": 3.0,
            "accel_x_mps2": 0.0,
            "accel_y_mps2": 9.80665 * math.sin(math.radians(moderate_roll)),
            "accel_z_mps2": 9.80665 * math.cos(math.radians(moderate_roll)),
        }
    )
    assert 0.0 < moderate.factor < 1.0

    severe = assess_stability(
        {
            "roll_deg": 31.0,
            "pitch_deg": 0.0,
            "accel_x_mps2": 0.0,
            "accel_y_mps2": 5.05,
            "accel_z_mps2": 8.41,
        }
    )
    assert severe.factor == 0.0

    solution = netuno_navigation_solution(
        -22.8,
        -43.2,
        0.0,
        -22.799,
        -43.2,
        0.8,
    )
    stopped = apply_stability_limit(solution, severe)
    assert stopped.throttle_norm == 0.0
    assert stopped.maneuver == "stability_stop"


def test_command_payload_carries_vessel_and_stability_fields() -> None:
    command = AutopilotCommand(
        command_sequence=7,
        target_pod_deg=45.0,
        throttle_norm=0.4,
        valid_for_ms=500,
        mission_id="rota-netuno",
        waypoint_index=1,
        drive_direction="reverse",
        steering_norm=-0.25,
        stability_factor=0.72,
        maneuver="reverse",
    )
    frame = FrameDecoder().feed(command.to_frame(1234))[0]
    payload = json.loads(frame.payload)
    assert payload["drive_direction"] == "reverse"
    assert payload["steering_norm"] == -0.25
    assert payload["stability_factor"] == 0.72
    assert payload["maneuver"] == "reverse"
