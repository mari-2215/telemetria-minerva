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
  final _name = TextEditingController(text: 'Rota de prova');
  final List<LatLng> _points = [];
  late Future<List<Mission>> _missions = widget.client.missions(widget.boatId);
  double _throttle = 0.55;
  String _strategy = 'balanced';
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
        waypoints: _points.map((point) => MissionWaypoint(latitude: point.latitude, longitude: point.longitude, toleranceM: 6)).toList(),
        cruiseThrottle: _throttle,
        strategy: _strategy,
      );
      await widget.client.activateMission(mission.id);
      _points.clear();
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rota enviada. Coloque CH3 em AUTO e use o botão latch do rádio para iniciar.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color _statusColor(String status) => switch (status) {
        'active' => Colors.green,
        'pending' => Colors.blue,
        'completed' => Colors.teal,
        'failed' => Colors.red,
        _ => Colors.blueGrey,
      };

  String _strategyLabel(String strategy) => strategy == 'best_time' ? 'Melhor tempo' : 'Controle fino';

  @override
  Widget build(BuildContext context) {
    final center = widget.initialPosition ?? const LatLng(-26.3044, -48.8464);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: MinervaAppBarTitle(title: 'Rotas · ${widget.boatId}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Nova trajetória', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text('Toque no mapa na ordem em que o barco deve visitar os pontos.'),
                  const SizedBox(height: 16),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nome da rota')),
                  const SizedBox(height: 14),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'balanced', icon: Icon(Icons.tune_rounded), label: Text('Controle fino')),
                      ButtonSegment(value: 'best_time', icon: Icon(Icons.timer_rounded), label: Text('Melhor tempo')),
                    ],
                    selected: {_strategy},
                    onSelectionChanged: (values) => setState(() => _strategy = values.first),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: Text(
                      _strategy == 'best_time'
                          ? 'O fuzzy mantém mais potência em retas e curvas médias, reduzindo apenas perto do waypoint ou com erro de rumo grande.'
                          : 'O fuzzy prioriza estabilidade, suavidade e menor consumo durante as correções de rumo.',
                      key: ValueKey(_strategy),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 410,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 16,
                          onTap: (_, point) => setState(() => _points.add(point)),
                        ),
                        children: [
                          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'br.org.minervanautica.telemetria'),
                          if (_points.length > 1)
                            PolylineLayer(polylines: [Polyline(points: _points, color: const Color(0xFF0B6CCB), strokeWidth: 6)]),
                          MarkerLayer(
                            markers: [
                              for (var index = 0; index < _points.length; index++)
                                Marker(
                                  point: _points[index],
                                  width: 42,
                                  height: 42,
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF082B5C)),
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
                      TextButton.icon(onPressed: _points.isEmpty ? null : () => setState(() => _points.removeLast()), icon: const Icon(Icons.undo_rounded), label: const Text('Desfazer')),
                      TextButton.icon(onPressed: _points.isEmpty ? null : () => setState(_points.clear), icon: const Icon(Icons.delete_outline_rounded), label: const Text('Limpar')),
                    ],
                  ),
                  Text('Limite de potência: ${(_throttle * 100).round()}%'),
                  Slider(
                    value: _throttle,
                    min: 0.15,
                    max: 0.85,
                    divisions: 14,
                    label: '${(_throttle * 100).round()}%',
                    onChanged: (value) => setState(() => _throttle = value),
                  ),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _saveAndActivate,
                    icon: const Icon(Icons.rocket_launch_rounded),
                    label: Text(_saving ? 'Enviando...' : 'Salvar e deixar pronta'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Rotas salvas', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          FutureBuilder<List<Mission>>(
            future: _missions,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
              }
              if (snapshot.hasError) return Text('Falha ao carregar rotas: ${snapshot.error}');
              final missions = snapshot.data ?? const [];
              if (missions.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Nenhuma rota salva ainda.'));
              return Column(
                children: missions.map((mission) => Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    leading: Icon(Icons.route_rounded, color: _statusColor(mission.status)),
                    title: Text(mission.name),
                    subtitle: Text('${mission.waypoints.length} pontos · ${_strategyLabel(mission.strategy)} · ${(mission.cruiseThrottle * 100).round()}% · ${mission.status}'),
                    trailing: mission.status == 'active' || mission.status == 'pending'
                        ? null
                        : IconButton(
                            tooltip: 'Preparar esta rota',
                            icon: const Icon(Icons.send_rounded),
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
