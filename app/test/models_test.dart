import 'package:flutter_test/flutter_test.dart';
import 'package:telemetria_minerva_app/models.dart';

void main() {
  test('parses boat summary and telemetry metrics', () {
    final summary = BoatSummary.fromJson({
      'boat_id': 'azimutal-01',
      'recorded_at': '2026-07-14T20:00:00Z',
      'severity': 'ok',
      'latitude': -22.8,
      'longitude': -43.2,
    });
    expect(summary.id, 'azimutal-01');
    expect(summary.latitude, -22.8);

    final telemetry = Telemetry.fromJson({
      'boat_id': 'azimutal-01',
      'sequence': 42,
      'recorded_at': '2026-07-14T20:00:00Z',
      'position': {'latitude_deg': -22.8, 'longitude_deg': -43.2},
      'power': {'battery_v': 12.4},
      'motion': {
        'accel_x_mps2': 0.0,
        'accel_y_mps2': 0.0,
        'accel_z_mps2': 9.81,
        'roll_deg': 3.5,
        'pitch_deg': -2.25,
        'yaw_deg': 127.75,
      },
      'control': {'mode': 'auto'},
      'status': {
        'severity': 'critical',
        'alarms': ['WATER_DETECTED']
      },
    });
    expect(telemetry.sequence, 42);
    expect(telemetry.alarms, ['WATER_DETECTED']);
    expect(telemetry.controlMode, 'auto');
    expect(telemetry.rollDeg, 3.5);
    expect(telemetry.pitchDeg, -2.25);
    expect(telemetry.yawDeg, 127.75);
  });

  test('falls back to accelerometer tilt while yaw is unavailable', () {
    final telemetry = Telemetry.fromJson({
      'boat_id': 'azimutal-01',
      'sequence': 43,
      'recorded_at': '2026-07-14T20:00:01Z',
      'motion': {
        'accel_x_mps2': 0.0,
        'accel_y_mps2': 0.0,
        'accel_z_mps2': 9.81,
      },
    });

    expect(telemetry.rollDeg, 0);
    expect(telemetry.pitchDeg, 0);
    expect(telemetry.yawDeg, isNull);
  });

  test('parses mission waypoints', () {
    final mission = Mission.fromJson({
      'mission_id': 'rota-01',
      'boat_id': 'azimutal-01',
      'name': 'Volta do lago',
      'status': 'pending',
      'cruise_throttle': 0.4,
      'waypoints': [
        {'latitude_deg': -22.8, 'longitude_deg': -43.2, 'tolerance_m': 6},
      ],
    });
    expect(mission.waypoints.single.toleranceM, 6);
    expect(mission.status, 'pending');
  });
}
