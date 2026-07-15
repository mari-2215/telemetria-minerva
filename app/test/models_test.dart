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
      'status': {'severity': 'critical', 'alarms': ['WATER_DETECTED']},
    });
    expect(telemetry.sequence, 42);
    expect(telemetry.alarms, ['WATER_DETECTED']);
  });
}

