import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/minerva_logo.dart';

class MissionPlannerScreen extends StatefulWidget {
  const MissionPlannerScreen({
    super.key,
    required this.client,
    required this.boatId,
    this.initialPosition,
  });
  final ApiClient client;
  final String boatId;
  final LatLng? initialPosition;

  @override
  State<MissionPlannerScreen> createState() => _MissionPlannerScreenState();
}

class _MissionPlannerScreenState extends State<MissionPlannerScreen> {
  final _name = TextEditingController(text: 'Rota de teste');
  final List<LatLng> _points = [];
  late Future<List<Mission>> _missions = widget.client.missions(widget.boatId);
  double _throttle = 0.45;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _missions = widget.client.missions(widget.boatId));

  Future<void> _saveAndActivate() async {
    if (_points.isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = 'Dê um nome e marque pelo menos um ponto no mapa.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final mission = await widget.client.createMission(
        boatId: widget.boatId,
        name: _name.text.trim(),
        waypoints: _points.map((point) => MissionWaypoint(latitude: point.latitude, longitude: point.longitude)).toList(),
        cruiseThrottle: _throttle,
      );
      await widget.client.activateMission(mission.id);
      _points.clear();
      _reload();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rota enviada. A Raspberry vai baixar e salvar a missão.')));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color _statusColor(String status) => switch (status) {
        'active' => Colors.greenAccent,
        'pending' => Colors.lightBlueAccent,
        'completed' => Colors.tealAccent,
        'failed' => Colors.redAccent,
        _ => Colors.white54,
      };

  @override
  Widget build(BuildContext context) {
    final center = widget.initialPosition ?? const LatLng(-22.8622, -43.2302);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: MinervaAppBarTitle(title: 'Rotas · ${widget.boatId}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Nova trajetória', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text('Toque no mapa na ordem em que o barco deve visitar os pontos.'),
                  const SizedBox(height: 12),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nome da rota', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 390,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 16,
                          onTap: (_, point) => setState(() => _points.add(point)),
                        ),
                        children: [
                          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'br.org.minervanautica.telemetria'),
                          if (_points.length > 1) PolylineLayer(polylines: [Polyline(points: _points, color: const Color(0xFF0284C7), strokeWidth: 5)]),
                          MarkerLayer(
                            markers: [
                              for (var index = 0; index < _points.length; index++)
                                Marker(
                                  point: _points[index],
                                  width: 38,
                                  height: 38,
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
                                    child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(child: Text('${_points.length} waypoint(s)')),
                      TextButton.icon(onPressed: _points.isEmpty ? null : () => setState(() => _points.removeLast()), icon: const Icon(Icons.undo), label: const Text('Desfazer')),
                      TextButton.icon(onPressed: _points.isEmpty ? null : () => setState(_points.clear), icon: const Icon(Icons.delete_outline), label: const Text('Limpar')),
                    ],
                  ),
                  Text('Potência de cruzeiro: ${(_throttle * 100).round()}%'),
                  Slider(value: _throttle, min: 0.15, max: 0.75, divisions: 12, onChanged: (value) => setState(() => _throttle = value)),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton.icon(onPressed: _saving ? null : _saveAndActivate, icon: const Icon(Icons.send), label: Text(_saving ? 'Enviando...' : 'Salvar e enviar ao barco')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Rotas salvas', style: Theme.of(context).textTheme.titleLarge),
          FutureBuilder<List<Mission>>(
            future: _missions,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
              if (snapshot.hasError) return Text('Falha ao carregar rotas: ${snapshot.error}');
              final missions = snapshot.data ?? const [];
              if (missions.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Nenhuma rota salva ainda.'));
              return Column(
                children: missions.map((mission) => Card(
                  child: ListTile(
                    leading: Icon(Icons.route, color: _statusColor(mission.status)),
                    title: Text(mission.name),
                    subtitle: Text('${mission.waypoints.length} pontos · ${mission.status} · ${(mission.cruiseThrottle * 100).round()}%'),
                    trailing: mission.status == 'active' || mission.status == 'pending'
                        ? null
                        : IconButton(
                            tooltip: 'Enviar esta rota',
                            icon: const Icon(Icons.send),
                            onPressed: () async { await widget.client.activateMission(mission.id); _reload(); },
                          ),
                  ),
                )).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
