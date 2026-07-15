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

  dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Servidor respondeu ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  void close() => _client.close();
}

