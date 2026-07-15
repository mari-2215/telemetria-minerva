import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/boat_attitude_view.dart';
import 'mission_planner_screen.dart';

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
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon), const SizedBox(height: 8), Text(value, style: Theme.of(context).textTheme.titleLarge), Text(label)]),
        ),
      );

  void _openPlanner() {
    final telemetry = _telemetry;
    final position = telemetry?.latitude != null && telemetry?.longitude != null ? LatLng(telemetry!.latitude!, telemetry.longitude!) : null;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => MissionPlannerScreen(client: widget.client, boatId: widget.boatId, initialPosition: position)));
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = _telemetry;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.boatId),
        actions: [
          IconButton(onPressed: _openPlanner, tooltip: 'Planejar rota', icon: const Icon(Icons.route)),
          IconButton(onPressed: _load, tooltip: 'Atualizar', icon: const Icon(Icons.refresh)),
        ],
      ),
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
                    _metric('Ângulo do pod', _number(telemetry.propulsion, 'pod_angle_deg', 'graus'), Icons.navigation),
                    _metric('Temperatura', _number(telemetry.environment, 'electronics_temp_c', '°C'), Icons.thermostat),
                    _metric('Modo', telemetry.controlMode.toUpperCase(), Icons.tune),
                  ],
                ),
                const SizedBox(height: 12),
                BoatAttitudeView(rollDeg: telemetry.rollDeg, pitchDeg: telemetry.pitchDeg),
                const SizedBox(height: 12),
                if (telemetry.latitude != null && telemetry.longitude != null)
                  SizedBox(
                    height: 390,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        children: [
                          FlutterMap(
                            options: MapOptions(initialCenter: LatLng(telemetry.latitude!, telemetry.longitude!), initialZoom: 15),
                            children: [
                              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'br.org.minervanautica.telemetria'),
                              MarkerLayer(markers: [
                                Marker(
                                  point: LatLng(telemetry.latitude!, telemetry.longitude!),
                                  width: 54,
                                  height: 54,
                                  child: Container(
                                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black, border: Border.all(color: Colors.white, width: 2), boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black54)]),
                                    child: const Icon(Icons.sailing, size: 34, color: Colors.white),
                                  ),
                                ),
                              ]),
                            ],
                          ),
                          Positioned(
                            left: 10,
                            top: 10,
                            child: Card(
                              color: const Color(0xE6020617),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                child: Text(
                                  'LAT  ${telemetry.latitude!.toStringAsFixed(6)}\nLON ${telemetry.longitude!.toStringAsFixed(6)}\nTEMP ${telemetry.temperatureC?.toStringAsFixed(1) ?? '--'} °C',
                                  style: const TextStyle(fontFamily: 'monospace', color: Colors.white, height: 1.45),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const Card(child: ListTile(leading: Icon(Icons.gps_off), title: Text('GPS sem posição válida'), subtitle: Text('O mapa aparece assim que o NEO-6M obtiver fix.'))),
                const SizedBox(height: 8),
                Text('Pacote ${telemetry.sequence} · ${telemetry.recordedAt.toLocal()}', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}
