import 'dart:math' as math;

class UserProfile {
  const UserProfile({
    required this.name,
    required this.role,
    required this.canControl,
    required this.canAcknowledgeAlerts,
  });

  final String name;
  final String role;
  final bool canControl;
  final bool canAcknowledgeAlerts;

  bool get isCaptain => canControl;
  String get label => isCaptain ? 'CAPITÃO' : 'TRIPULAÇÃO';

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        name: json['name'] as String? ?? 'Usuário',
        role: json['role'] as String? ?? 'crew',
        canControl: json['can_control'] as bool? ?? false,
        canAcknowledgeAlerts: json['can_acknowledge_alerts'] as bool? ?? false,
      );
}

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
  Map<String, dynamic> get motion => (raw['motion'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get propulsion => (raw['propulsion'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get control => (raw['control'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get autopilot => (raw['autopilot'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get link => (raw['link'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get status => (raw['status'] as Map?)?.cast<String, dynamic>() ?? const {};
  double? get latitude => (position['latitude_deg'] as num?)?.toDouble();
  double? get longitude => (position['longitude_deg'] as num?)?.toDouble();
  double? get temperatureC => (environment['electronics_temp_c'] as num?)?.toDouble();
  String get controlMode => control['mode']?.toString() ?? 'desconhecido';
  bool get autopilotLatched => autopilot['latched'] as bool? ?? false;
  bool get autopilotArmed => autopilot['armed'] as bool? ?? controlMode == 'auto';
  bool get rcHealthy => control['rc_healthy'] as bool? ?? false;

  bool get motorOn {
    final explicit = propulsion['motor_on'];
    if (explicit is bool) return explicit;
    final esc = (propulsion['esc_pwm_us'] as num?)?.toDouble();
    if (esc != null) return esc > 1020;
    return ((propulsion['throttle_norm'] as num?)?.toDouble() ?? 0).abs() > 0.02;
  }

  double? _motionNumber(String key) {
    final value = (motion[key] as num?)?.toDouble();
    return value != null && value.isFinite ? value : null;
  }

  double get rollDeg {
    final reported = _motionNumber('roll_deg');
    if (reported != null) return reported;
    final y = (motion['accel_y_mps2'] as num?)?.toDouble();
    final z = (motion['accel_z_mps2'] as num?)?.toDouble();
    return y == null || z == null ? 0 : math.atan2(y, z) * 180 / math.pi;
  }

  double get pitchDeg {
    final reported = _motionNumber('pitch_deg');
    if (reported != null) return reported;
    final x = (motion['accel_x_mps2'] as num?)?.toDouble();
    final y = (motion['accel_y_mps2'] as num?)?.toDouble();
    final z = (motion['accel_z_mps2'] as num?)?.toDouble();
    return x == null || y == null || z == null ? 0 : math.atan2(-x, math.sqrt(y * y + z * z)) * 180 / math.pi;
  }

  double? get yawDeg => _motionNumber('yaw_deg');
  List<String> get alarms => ((status['alarms'] as List?) ?? const []).map((value) => value.toString()).toList();
  factory Telemetry.fromJson(Map<String, dynamic> json) => Telemetry(raw: json);
}

class MissionWaypoint {
  const MissionWaypoint({required this.latitude, required this.longitude, this.toleranceM = 8});
  final double latitude;
  final double longitude;
  final double toleranceM;

  factory MissionWaypoint.fromJson(Map<String, dynamic> json) => MissionWaypoint(
        latitude: (json['latitude_deg'] as num).toDouble(),
        longitude: (json['longitude_deg'] as num).toDouble(),
        toleranceM: (json['tolerance_m'] as num?)?.toDouble() ?? 8,
      );

  Map<String, dynamic> toJson() => {
        'latitude_deg': latitude,
        'longitude_deg': longitude,
        'tolerance_m': toleranceM,
      };
}

class Mission {
  const Mission({
    required this.id,
    required this.boatId,
    required this.name,
    required this.status,
    required this.waypoints,
    required this.cruiseThrottle,
    required this.strategy,
    required this.startConfirmed,
  });

  final String id;
  final String boatId;
  final String name;
  final String status;
  final List<MissionWaypoint> waypoints;
  final double cruiseThrottle;
  final String strategy;
  final bool startConfirmed;

  bool get isPrepared => status == 'pending' || status == 'active';
  bool get canDelete => status != 'active' && !startConfirmed;

  factory Mission.fromJson(Map<String, dynamic> json) => Mission(
        id: json['mission_id'] as String,
        boatId: json['boat_id'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        waypoints: ((json['waypoints'] as List?) ?? const [])
            .map((value) => MissionWaypoint.fromJson((value as Map).cast<String, dynamic>()))
            .toList(),
        cruiseThrottle: (json['cruise_throttle'] as num?)?.toDouble() ?? 0.45,
        strategy: json['strategy'] as String? ?? 'balanced',
        startConfirmed: json['start_confirmed'] as bool? ?? false,
      );
}

class RouteRecording {
  const RouteRecording({
    required this.id,
    required this.boatId,
    required this.name,
    required this.status,
    required this.points,
    required this.startedAt,
    required this.cruiseThrottle,
    required this.strategy,
  });

  final String id;
  final String boatId;
  final String name;
  final String status;
  final List<MissionWaypoint> points;
  final DateTime startedAt;
  final double cruiseThrottle;
  final String strategy;

  factory RouteRecording.fromJson(Map<String, dynamic> json) => RouteRecording(
        id: json['recording_id'] as String,
        boatId: json['boat_id'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        points: ((json['points'] as List?) ?? const [])
            .map((value) => MissionWaypoint.fromJson((value as Map).cast<String, dynamic>()))
            .toList(),
        startedAt: DateTime.parse(json['started_at'] as String),
        cruiseThrottle: (json['cruise_throttle'] as num?)?.toDouble() ?? 0.45,
        strategy: json['strategy'] as String? ?? 'balanced',
      );
}
