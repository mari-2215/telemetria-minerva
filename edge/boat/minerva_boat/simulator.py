from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import sys
import time

from minerva_protocol import Frame, MessageType, encode_frame


def sample(boat_id: str, sequence: int) -> dict[str, object]:
    phase = sequence / 30.0
    battery = 12.7 - min(sequence / 10000.0, 1.8)
    return {
        "schema_version": 1,
        "boat_id": boat_id,
        "sequence": sequence,
        "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "position": {
            "latitude_deg": -22.8622 + math.sin(phase) * 0.001,
            "longitude_deg": -43.2302 + math.cos(phase) * 0.001,
            "speed_mps": 1.2 + math.sin(phase * 2) * 0.2,
            "course_deg": (sequence * 3) % 360,
            "fix": 3,
            "hdop": 0.9,
        },
        "power": {"battery_v": battery, "current_a": 4.2 + math.sin(phase) * 1.1},
        "motion": {"accel_x_mps2": 0.1, "accel_y_mps2": 0.2, "accel_z_mps2": 9.78},
        "environment": {"electronics_temp_c": 34.0, "humidity_pct": 55.0, "water_detected": False},
        "control": {"mode": "manual", "recording_active": False, "rc_healthy": True, "failsafe_active": False},
        "autopilot": {"enabled": False, "command_fresh": False, "last_command_sequence": 0, "command_age_ms": 0, "target_pod_deg": 45.0, "mission_id": "", "waypoint_index": 0},
        "propulsion": {"pod_angle_deg": 45.0, "target_pod_angle_deg": 45.0, "rudder_norm": 0.0, "throttle_norm": 0.4, "servo1_pwm_us": 833, "servo2_pwm_us": 833, "esc_pwm_us": 1400},
        "status": {"severity": "ok", "alarms": []},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Gera quadros seriais simulados da Telemetria Minerva")
    parser.add_argument("--boat-id", default="azimutal-01")
    parser.add_argument("--rate", type=float, default=2.0)
    parser.add_argument("--count", type=int, default=0, help="0 executa continuamente")
    args = parser.parse_args()

    sequence = 0
    while args.count == 0 or sequence < args.count:
        payload = json.dumps(sample(args.boat_id, sequence), separators=(",", ":")).encode()
        frame = Frame(MessageType.TELEMETRY, sequence, int(time.monotonic() * 1000) & 0xFFFFFFFF, payload)
        sys.stdout.buffer.write(encode_frame(frame))
        sys.stdout.buffer.flush()
        sequence += 1
        time.sleep(1.0 / args.rate)


if __name__ == "__main__":
    main()
