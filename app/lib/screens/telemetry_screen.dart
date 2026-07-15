import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';

class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({super.key, required this.client, required this.boatId});
  final ApiClient client;
  final String boatId;

  @override
  State<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends State<TelemetryScreen> {
  Telemetry? _telemetry;
  Object? _error;
  Timer? _timer;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final value = await widget.client.latest(widget.boatId);
      if (mounted) setState(() { _telemetry = value; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _fetching = false;
    }
  }

  String _number(Map<String, dynamic> values, String key, String suffix, {int decimals = 1}) {
    final value = values[key] as num?;
    return value == null ? '--' : '${value.toStringAsFixed(decimals)} $suffix';
  }

  Widget _metric(String label, String value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [Icon(icon), const SizedBox(height: 8), Text(value, style: Theme.of(context).textTheme.titleLarge), Text(label)]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final telemetry = _telemetry;
    return Scaffold(
      appBar: AppBar(title: Text(widget.boatId), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: telemetry == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text('Falha: $_error'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (telemetry.alarms.isNotEmpty)
                  Card(color: Theme.of(context).colorScheme.errorContainer, child: ListTile(leading: const Icon(Icons.warning), title: const Text('Alarmes ativos'), subtitle: Text(telemetry.alarms.join(', ')))),
                GridView.count(
                  crossAxisCount: MediaQuery.sizeOf(context).width > 700 ? 4 : 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.35,
                  children: [
                    _metric('Bateria', _number(telemetry.power, 'battery_v', 'V'), Icons.battery_charging_full),
                    _metric('Corrente', _number(telemetry.power, 'current_a', 'A'), Icons.electric_bolt),
                    _metric('Velocidade', _number(telemetry.position, 'speed_mps', 'm/s'), Icons.speed),
                    _metric('Angulo do pod', _number(telemetry.propulsion, 'pod_angle_deg', 'graus'), Icons.navigation),
                    _metric('Temperatura', _number(telemetry.environment, 'electronics_temp_c', 'C'), Icons.thermostat),
                    _metric('RSSI', _number(telemetry.link, 'rssi_dbm', 'dBm', decimals: 0), Icons.network_cell),
                  ],
                ),
                const SizedBox(height: 12),
                if (telemetry.latitude != null && telemetry.longitude != null)
                  SizedBox(
                    height: 360,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: FlutterMap(
                        options: MapOptions(initialCenter: LatLng(telemetry.latitude!, telemetry.longitude!), initialZoom: 15),
                        children: [
                          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'br.org.minervanautica.telemetria'),
                          MarkerLayer(markers: [Marker(point: LatLng(telemetry.latitude!, telemetry.longitude!), width: 48, height: 48, child: const Icon(Icons.sailing, size: 42, color: Colors.cyanAccent))]),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Pacote ${telemetry.sequence} - ${telemetry.recordedAt.toLocal()}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}
