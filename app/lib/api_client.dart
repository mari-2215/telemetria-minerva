import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({required String baseUrl, required this.token, http.Client? client})
      : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};
  Map<String, String> get _jsonHeaders => {..._headers, 'Content-Type': 'application/json'};

  Future<UserProfile> me() async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/me'), headers: _headers);
    return UserProfile.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<List<BoatSummary>> boats() async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/boats'), headers: _headers);
    final decoded = _decode(response) as List<dynamic>;
    return decoded.map((value) => BoatSummary.fromJson((value as Map).cast<String, dynamic>())).toList();
  }

  Future<Telemetry> latest(String boatId) async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/boats/$boatId/latest'), headers: _headers);
    return Telemetry.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<List<Telemetry>> samples(String boatId, {int limit = 500}) async {
    final uri = Uri.parse('$baseUrl/v1/boats/$boatId/samples').replace(queryParameters: {'limit': '$limit'});
    final response = await _client.get(uri, headers: _headers);
    final decoded = _decode(response) as List<dynamic>;
    return decoded.map((value) => Telemetry.fromJson((value as Map).cast<String, dynamic>())).toList();
  }

  Future<List<Mission>> missions(String boatId) async {
    final uri = Uri.parse('$baseUrl/v1/missions').replace(queryParameters: {'boat_id': boatId});
    final response = await _client.get(uri, headers: _headers);
    final decoded = _decode(response) as List<dynamic>;
    return decoded.map((value) => Mission.fromJson((value as Map).cast<String, dynamic>())).toList();
  }

  Future<Mission> createMission({
    required String boatId,
    required String name,
    required List<MissionWaypoint> waypoints,
    required double cruiseThrottle,
    required String strategy,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/missions'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'boat_id': boatId,
        'name': name,
        'waypoints': waypoints.map((value) => value.toJson()).toList(),
        'cruise_throttle': cruiseThrottle,
        'strategy': strategy,
      }),
    );
    return Mission.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<Mission> activateMission(String missionId) async {
    final response = await _client.post(Uri.parse('$baseUrl/v1/missions/$missionId/activate'), headers: _headers);
    return Mission.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<Mission> configureMission(
    String missionId, {
    required String strategy,
    required double cruiseThrottle,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/missions/$missionId/configure'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'strategy': strategy,
        'cruise_throttle': cruiseThrottle,
      }),
    );
    return Mission.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<Mission> setMissionReady(String missionId, bool ready) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/missions/$missionId/ready'),
      headers: _jsonHeaders,
      body: jsonEncode({'ready': ready}),
    );
    return Mission.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<void> deleteMission(String missionId) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/v1/missions/$missionId'),
      headers: _headers,
    );
    _decode(response);
  }

  Future<RouteRecording?> activeRecording(String boatId) async {
    final response = await _client.get(Uri.parse('$baseUrl/v1/boats/$boatId/recordings/active'), headers: _headers);
    final decoded = _decode(response);
    if (decoded == null) return null;
    return RouteRecording.fromJson((decoded as Map).cast<String, dynamic>());
  }

  Future<RouteRecording> startRecording({
    required String boatId,
    required String name,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/boats/$boatId/recordings/start'),
      headers: _jsonHeaders,
      body: jsonEncode({'name': name}),
    );
    return RouteRecording.fromJson((_decode(response) as Map).cast<String, dynamic>());
  }

  Future<Mission> stopRecording(String recordingId) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/recordings/$recordingId/stop'),
      headers: _headers,
    );
    final decoded = (_decode(response) as Map).cast<String, dynamic>();
    return Mission.fromJson((decoded['mission'] as Map).cast<String, dynamic>());
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Servidor respondeu ${response.statusCode}: ${response.body}');
    }
    if (response.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  void close() => _client.close();
}
