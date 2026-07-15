class BoatSummary {
  const BoatSummary({
    required this.id,
    required this.recordedAt,
    required this.severity,
    this.latitude,
    this.longitude,
  });

  final String id;
  final DateTime recordedAt;
  final String severity;
  final double? latitude;
  final double? longitude;

  factory BoatSummary.fromJson(Map<String, dynamic> json) => BoatSummary(
        id: json['boat_id'] as String,
        recordedAt: DateTime.parse(json['recorded_at'] as String),
        severity: json['severity'] as String? ?? 'warning',
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
      );
}

class Telemetry {
  const Telemetry({required this.raw});

  final Map<String, dynamic> raw;

  String get boatId => raw['boat_id'] as String;
  int get sequence => raw['sequence'] as int;
  DateTime get recordedAt => DateTime.parse(raw['recorded_at'] as String);
  Map<String, dynamic> get position => (raw['position'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get power => (raw['power'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get environment => (raw['environment'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get propulsion => (raw['propulsion'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get link => (raw['link'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get status => (raw['status'] as Map?)?.cast<String, dynamic>() ?? const {};
  double? get latitude => (position['latitude_deg'] as num?)?.toDouble();
  double? get longitude => (position['longitude_deg'] as num?)?.toDouble();
  List<String> get alarms => ((status['alarms'] as List?) ?? const []).map((value) => value.toString()).toList();

  factory Telemetry.fromJson(Map<String, dynamic> json) => Telemetry(raw: json);
}

