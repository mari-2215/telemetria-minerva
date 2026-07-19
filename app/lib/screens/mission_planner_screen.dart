import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/minerva_logo.dart';
import '../widgets/route_preview_map.dart';

enum _PlannerView { library, create, preview }

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

  _PlannerView _view = _PlannerView.library;
  Mission? _selectedMission;
  double _throttle = 0.55;
  String _strategy = 'balanced';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() => _missions = widget.client.missions(widget.boatId));
  }

  void _showLibrary() {
    setState(() {
      _view = _PlannerView.library;
      _selectedMission = null;
      _error = null;
    });
  }

  void _openCreate() {
    setState(() {
      _view = _PlannerView.create;
      _selectedMission = null;
      _error = null;
    });
  }

  void _openPreview(Mission mission) {
    setState(() {
      _selectedMission = mission;
      _view = _PlannerView.preview;
      _error = null;
    });
  }

  Future<void> _saveDraft() async {
    if (_points.isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = 'Dê um nome e marque pelo menos um ponto no mapa.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.client.createMission(
        boatId: widget.boatId,
        name: _name.text.trim(),
        waypoints: _points
            .map(
              (point) => MissionWaypoint(
                latitude: point.latitude,
                longitude: point.longitude,
                toleranceM: 6,
              ),
            )
            .toList(),
        cruiseThrottle: _throttle,
        strategy: _strategy,
      );

      _points.clear();
      _name.text = 'Rota de prova';
      _reload();
      _showLibrary();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Rota salva. Toque nela para pré-visualizar e enviar.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendMission(Mission mission) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final activated = await widget.client.activateMission(mission.id);
      if (!mounted) return;
      Navigator.of(context).pop(activated);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showMissionActions(Mission mission) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_rounded),
                title: const Text('Pré-visualizar rota'),
                onTap: () {
                  Navigator.pop(context);
                  _openPreview(mission);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: Colors.red.shade700),
                title: Text('Apagar rota', style: TextStyle(color: Colors.red.shade700)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(mission);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Mission mission) async {
    if (!mission.canDelete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Uma rota em execução ou já autorizada não pode ser apagada.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever_rounded),
        title: const Text('Apagar rota?'),
        content: Text(
          'A rota “${mission.name}” será apagada permanentemente.\n\nEsta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await widget.client.deleteMission(mission.id);
      _selectedMission = null;
      _reload();
      _showLibrary();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rota “${mission.name}” apagada.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível apagar: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _strategyLabel(String strategy) => strategy == 'best_time' ? 'Melhor tempo' : 'Controle fino';

  String _statusLabel(Mission mission) {
    if (mission.status == 'pending' && !mission.startConfirmed) {
      return 'Enviada · aguardando latch e capitão';
    }
    if (mission.status == 'pending' && mission.startConfirmed) {
      return 'Partida autorizada · aguardando barco';
    }
    return switch (mission.status) {
      'draft' => 'Salva',
      'active' => 'Em execução',
      'completed' => 'Concluída',
      'cancelled' => 'Cancelada',
      'failed' => 'Falhou',
      _ => mission.status,
    };
  }

  Color _statusColor(String status) => switch (status) {
        'active' => Colors.green,
        'pending' => Colors.blue,
        'completed' => Colors.teal,
        'failed' => Colors.red,
        'cancelled' => Colors.orange,
        _ => Colors.blueGrey,
      };

  String get _title => switch (_view) {
        _PlannerView.library => 'Rotas · ${widget.boatId}',
        _PlannerView.create => 'Criar rota',
        _PlannerView.preview => 'Pré-visualizar rota',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        leading: _view == _PlannerView.library
            ? null
            : IconButton(
                onPressed: _showLibrary,
                tooltip: 'Voltar para rotas',
                icon: const Icon(Icons.arrow_back_rounded),
              ),
        title: MinervaAppBarTitle(title: _title),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.025, 0.015),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: switch (_view) {
          _PlannerView.library => _libraryView(),
          _PlannerView.create => _createView(),
          _PlannerView.preview => _previewView(),
        },
      ),
    );
  }

  Widget _libraryView() {
    return ListView(
      key: const ValueKey('route-library'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      children: [
        Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _openCreate,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      Icons.add_road_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Criar rota do zero',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                        SizedBox(height: 4),
                        Text('Abra o mapa e marque os waypoints na ordem da prova.'),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text('Escolher uma rota já criada', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Toque para pré-visualizar. Pressione e segure para abrir as opções.'),
        const SizedBox(height: 10),
        FutureBuilder<List<Mission>>(
          future: _missions,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: const Text('Falha ao carregar as rotas'),
                  subtitle: Text('${snapshot.error}'),
                  trailing: IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
                ),
              );
            }

            final missions = snapshot.data ?? const [];
            if (missions.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(22),
                  child: Column(
                    children: [
                      Icon(Icons.route_outlined, size: 42),
                      SizedBox(height: 10),
                      Text('Nenhuma rota salva ainda.', style: TextStyle(fontWeight: FontWeight.w800)),
                      SizedBox(height: 4),
                      Text(
                        'Crie uma rota do zero ou grave uma trajetória real.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }

            return Column(
              children: [
                for (final mission in missions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        onTap: () => _openPreview(mission),
                        onLongPress: () => _showMissionActions(mission),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _statusColor(mission.status).withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(Icons.route_rounded, color: _statusColor(mission.status)),
                        ),
                        title: Text(mission.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          '${mission.waypoints.length} pontos · '
                          '${_strategyLabel(mission.strategy)} · '
                          '${(mission.cruiseThrottle * 100).round()}%\n'
                          '${_statusLabel(mission)}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right_rounded),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _previewView() {
    final mission = _selectedMission;
    if (mission == null) return const SizedBox.shrink();

    final points = mission.waypoints
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);
    final executing = mission.status == 'active';

    return ListView(
      key: ValueKey('route-preview-${mission.id}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      children: [
        RoutePreviewMap(
          points: points,
          currentPosition: widget.initialPosition,
          height: 360,
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(mission.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.pin_drop_rounded, size: 18),
                      label: Text('${mission.waypoints.length} pontos'),
                    ),
                    Chip(
                      avatar: const Icon(Icons.speed_rounded, size: 18),
                      label: Text('${(mission.cruiseThrottle * 100).round()}%'),
                    ),
                    Chip(
                      avatar: const Icon(Icons.psychology_alt_rounded, size: 18),
                      label: Text(_strategyLabel(mission.strategy)),
                    ),
                    Chip(
                      avatar: Icon(Icons.circle, size: 12, color: _statusColor(mission.status)),
                      label: Text(_statusLabel(mission)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy || executing ? null : () => _sendMission(mission),
                  icon: Icon(executing ? Icons.directions_boat_filled_rounded : Icons.send_rounded),
                  label: Text(
                    executing
                        ? 'Rota em execução'
                        : _busy
                            ? 'Enviando...'
                            : 'Enviar esta rota para o barco',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _confirmDelete(mission),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Apagar esta rota'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _createView() {
    final center = widget.initialPosition ?? const LatLng(-26.3044, -48.8464);

    return ListView(
      key: const ValueKey('route-create'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Nova rota', style: Theme.of(context).textTheme.titleLarge),
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
                        ? 'O fuzzy mantém mais potência em retas e curvas médias, reduzindo perto do waypoint ou com erro de rumo grande.'
                        : 'O fuzzy prioriza estabilidade, suavidade e menor consumo durante as correções de rumo.',
                    key: ValueKey(_strategy),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 410,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: ColoredBox(
                      color: const Color(0xFFDDE7EF),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 16,
                          onTap: (_, point) => setState(() => _points.add(point)),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'br.org.minervanautica.telemetria',
                          ),
                          if (_points.length > 1)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _points,
                                  color: const Color(0xFF0B6CCB),
                                  strokeWidth: 6,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              for (var index = 0; index < _points.length; index++)
                                Marker(
                                  point: _points[index],
                                  width: 42,
                                  height: 42,
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF082B5C),
                                    ),
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: Text('${_points.length} waypoint(s)')),
                    TextButton.icon(
                      onPressed: _points.isEmpty ? null : () => setState(() => _points.removeLast()),
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Desfazer'),
                    ),
                    TextButton.icon(
                      onPressed: _points.isEmpty ? null : () => setState(_points.clear),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Limpar'),
                    ),
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
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveDraft,
                  icon: const Icon(Icons.save_rounded),
                  label: Text(_busy ? 'Salvando...' : 'Salvar rota'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
