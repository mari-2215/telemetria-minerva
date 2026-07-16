from __future__ import annotations

import base64
from datetime import datetime, timezone
import math
import struct
from typing import Any

from .model import Telemetry, TelemetryValidationError


LORA_PAYLOAD_VERSION = 2
_PAYLOAD_V1 = struct.Struct("<BHIIiiHHHhhHHhH")
_PAYLOAD_V2 = struct.Struct("<BHIIiiHHHhhHHhHhhH")
_ORIENTATION_UNAVAILABLE = -32768
_YAW_UNAVAILABLE = 65535

FLAG_GPS_VALID = 1 << 0
FLAG_WATER_DETECTED = 1 << 1
FLAG_RC_HEALTHY = 1 << 2
FLAG_FAILSAFE_ACTIVE = 1 << 3
FLAG_ENVIRONMENT_VALID = 1 << 4

ALARM_WATER = 1 << 0
ALARM_BATTERY = 1 << 1
ALARM_RC_LOST = 1 << 2
ALARM_SENSOR = 1 << 3


def _clamp(value: float, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, int(round(value))))


def _number(mapping: dict[str, Any], key: str, default: float = 0.0) -> float:
    value = mapping.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return default
    return float(value)


def _orientation_cdeg(mapping: dict[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return _ORIENTATION_UNAVAILABLE
    return _clamp(float(value) * 100, -32767, 32767)


def _yaw_cdeg(mapping: dict[str, Any]) -> int:
    value = mapping.get("yaw_deg")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return _YAW_UNAVAILABLE
    return _clamp(float(value) % 360.0 * 100, 0, 35999)


def encode_lora_payload(telemetry: Telemetry) -> bytes:
    value = telemetry.data
    position = value.get("position") or {}
    power = value.get("power") or {}
    environment = value.get("environment") or {}
    motion = value.get("motion") or {}
    propulsion = value.get("propulsion") or {}
    control = value.get("control") or {}
    alarms = set((value.get("status") or {}).get("alarms") or [])
    flags = 0
    if position.get("fix", 0) and "latitude_deg" in position and "longitude_deg" in position:
        flags |= FLAG_GPS_VALID
    if environment.get("water_detected"):
        flags |= FLAG_WATER_DETECTED
    if control.get("rc_healthy", propulsion.get("rc_healthy")):
        flags |= FLAG_RC_HEALTHY
    if control.get("failsafe_active", propulsion.get("failsafe_active")):
        flags |= FLAG_FAILSAFE_ACTIVE
    if "electronics_temp_c" in environment or "humidity_pct" in environment:
        flags |= FLAG_ENVIRONMENT_VALID

    alarm_bits = 0
    if "WATER_DETECTED" in alarms:
        alarm_bits |= ALARM_WATER
    if "BATTERY_CRITICAL" in alarms:
        alarm_bits |= ALARM_BATTERY
    if "RC_SIGNAL_LOST" in alarms:
        alarm_bits |= ALARM_RC_LOST
    if any(str(item).endswith("_UNAVAILABLE") for item in alarms):
        alarm_bits |= ALARM_SENSOR

    recorded = datetime.fromisoformat(telemetry.recorded_at.replace("Z", "+00:00"))
    return _PAYLOAD_V2.pack(
        LORA_PAYLOAD_VERSION,
        flags,
        telemetry.sequence & 0xFFFFFFFF,
        int(recorded.timestamp()) & 0xFFFFFFFF,
        _clamp(_number(position, "latitude_deg") * 10_000_000, -900_000_000, 900_000_000),
        _clamp(_number(position, "longitude_deg") * 10_000_000, -1_800_000_000, 1_800_000_000),
        _clamp(_number(position, "speed_mps") * 100, 0, 65535),
        _clamp(_number(position, "course_deg") * 100, 0, 35999),
        _clamp(_number(power, "battery_v") * 1000, 0, 65535),
        _clamp(_number(power, "current_a") * 1000, -32768, 32767),
        _clamp(_number(environment, "electronics_temp_c") * 100, -32768, 32767),
        _clamp(_number(environment, "humidity_pct") * 100, 0, 10000),
        _clamp(_number(propulsion, "pod_angle_deg") * 100, 0, 27000),
        _clamp(_number(propulsion, "throttle_norm") * 1000, -1000, 1000),
        alarm_bits,
        _orientation_cdeg(motion, "roll_deg"),
        _orientation_cdeg(motion, "pitch_deg"),
        _yaw_cdeg(motion),
    )


def decode_lora_payload(payload: bytes, boat_id: str, *, rssi_dbm: float | None = None, snr_db: float | None = None) -> Telemetry:
    if len(payload) == _PAYLOAD_V1.size:
        unpacked = _PAYLOAD_V1.unpack(payload)
        if unpacked[0] != 1:
            raise TelemetryValidationError("unsupported LoRa payload version")
        roll_cdeg = pitch_cdeg = _ORIENTATION_UNAVAILABLE
        yaw_cdeg = _YAW_UNAVAILABLE
    elif len(payload) == _PAYLOAD_V2.size:
        unpacked = _PAYLOAD_V2.unpack(payload)
        if unpacked[0] != LORA_PAYLOAD_VERSION:
            raise TelemetryValidationError("unsupported LoRa payload version")
        roll_cdeg, pitch_cdeg, yaw_cdeg = unpacked[-3:]
        unpacked = unpacked[:-3]
    else:
        raise TelemetryValidationError(
            f"LoRa payload must be {_PAYLOAD_V1.size} or {_PAYLOAD_V2.size} bytes"
        )

    (
        version,
        flags,
        sequence,
        unix_time,
        latitude_e7,
        longitude_e7,
        speed_cms,
        course_cdeg,
        battery_mv,
        current_ma,
        temperature_cdeg,
        humidity_centi,
        pod_cdeg,
        throttle_milli,
        alarm_bits,
    ) = unpacked

    alarms: list[str] = []
    for bit, name in (
        (ALARM_WATER, "WATER_DETECTED"),
        (ALARM_BATTERY, "BATTERY_CRITICAL"),
        (ALARM_RC_LOST, "RC_SIGNAL_LOST"),
        (ALARM_SENSOR, "SENSOR_UNAVAILABLE"),
    ):
        if alarm_bits & bit:
            alarms.append(name)

    result: dict[str, Any] = {
        "schema_version": 1,
        "boat_id": boat_id,
        "sequence": sequence,
        "recorded_at": datetime.fromtimestamp(unix_time, timezone.utc).isoformat().replace("+00:00", "Z"),
        "position": {
            "latitude_deg": latitude_e7 / 10_000_000,
            "longitude_deg": longitude_e7 / 10_000_000,
            "speed_mps": speed_cms / 100,
            "course_deg": course_cdeg / 100,
            "fix": 3 if flags & FLAG_GPS_VALID else 0,
        },
        "power": {"battery_v": battery_mv / 1000, "current_a": current_ma / 1000},
        "environment": {
            "electronics_temp_c": temperature_cdeg / 100,
            "humidity_pct": humidity_centi / 100,
            "water_detected": bool(flags & FLAG_WATER_DETECTED),
        },
        "propulsion": {
            "pod_angle_deg": pod_cdeg / 100,
            "throttle_norm": throttle_milli / 1000,
            "rc_healthy": bool(flags & FLAG_RC_HEALTHY),
            "failsafe_active": bool(flags & FLAG_FAILSAFE_ACTIVE),
        },
        "status": {"severity": "critical" if alarms else "ok", "alarms": alarms},
    }
    orientation = {
        key: value / 100
        for key, value in (("roll_deg", roll_cdeg), ("pitch_deg", pitch_cdeg))
        if value != _ORIENTATION_UNAVAILABLE
    }
    if yaw_cdeg != _YAW_UNAVAILABLE:
        orientation["yaw_deg"] = yaw_cdeg / 100
    if orientation:
        result["motion"] = orientation
    if rssi_dbm is not None or snr_db is not None:
        result["link"] = {}
        if rssi_dbm is not None:
            result["link"]["rssi_dbm"] = rssi_dbm
        if snr_db is not None:
            result["link"]["snr_db"] = snr_db
    return Telemetry.from_dict(result)


def decode_base64_lora_payload(value: str, boat_id: str, **link: float | None) -> Telemetry:
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise TelemetryValidationError("invalid base64 LoRa payload") from exc
    return decode_lora_payload(raw, boat_id, **link)
