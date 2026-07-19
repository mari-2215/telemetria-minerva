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
  State<MissionPlannerScreen> createState() =>
      _MissionPlannerScreenState();
}

class _MissionPlannerScreenState extends State<MissionPlannerScreen> {
  final _name = TextEditingController(text: 'Rota de prova');
  final List<LatLng> _points = [];

  late Future<List<Mission>> _missions =
      widget.client.missions(widget.boatId);

  _PlannerView _view = _PlannerView.library;
  Mission? _selectedMission;
  double _throttle = 0.55;
  String _strategy = 'balanced';
  bool _busy = false;
  String? _error;

  double get _effectiveThrottle =>
      _strategy == 'best_time' ? 1.0 : _throttle;

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
      _strategy = 'balanced';
      _throttle = 0.55;
      _error = null;
    });
  }

  void _openPreview(Mission mission) {
    setState(() {
      _selectedMission = mission;
      _strategy = mission.strategy;
      _throttle = mission.strategy == 'best_time'
          ? 0.55
          : mission.cruiseThrottle.clamp(0.15, 0.85).toDouble();
      _view = _PlannerView.preview;
      _error = null;
    });
  }

  Future<void> _saveDraft() async {
    if (_points.isEmpty || _name.text.trim().isEmpty) {
      setState(
        () => _error =
            'Dê um nome e marque pelo menos um destino no mapa.',
      );
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
        cruiseThrottle: _effectiveThrottle,
        strategy: _strategy,
      );

      _points.clear();
      _name.text = 'Rota de prova';
      _reload();
      _showLibrary();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Rota salva. Toque nela para pré-visualizar e enviar.',
            ),
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
      final configured = await widget.client.configureMission(
        mission.id,
        strategy: _strategy,
        cruiseThrottle: _effectiveThrottle,
      );
      final activated =
          await widget.client.activateMission(configured.id);
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
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red.shade700,
                ),
                title: Text(
                  'Apagar rota',
                  style: TextStyle(color: Colors.red.shade700),
                ),
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
          content: Text(
            'Uma rota em execução ou já autorizada não pode ser apagada.',
          ),
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
          'A rota “${mission.name}” será apagada permanentemente.\n\n'
          'Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
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

  String _strategyLabel(String strategy) =>
      strategy == 'best_time' ? 'Melhor tempo' : 'Limite de potência';

  String _powerLabel(Mission mission) => mission.strategy == 'best_time'
      ? 'potência dinâmica'
      : 'máx. ${(mission.cruiseThrottle * 100).round()}%';

  String _statusLabel(Mission mission) {
    if (mission.status == 'pending' && !mission.startConfirmed) {
      return 'Enviada · aguardando latch';
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
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.add_road_rounded, size: 44),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Criar rota do zero',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Marque somente os destinos. A largada será a posição atual do barco.',
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Escolher uma rota já criada',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        const Text(
          'Toque para pré-visualizar. Pressione e segure para abrir as opções.',
        ),
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
                  trailing: IconButton(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
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
                      Text(
                        'Nenhuma rota salva ainda.',
                        style: TextStyle(fontWeight: FontWeight.w800),
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
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        onTap: () => _openPreview(mission),
                        onLongPress: () => _showMissionActions(mission),
                        leading: Icon(
                          Icons.route_rounded,
                          color: _statusColor(mission.status),
                          size: 34,
                        ),
                        title: Text(
                          mission.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        subtitle: Text(
                          '${mission.waypoints.length} destinos · '
                          '${_strategyLabel(mission.strategy)} · '
                          '${_powerLabel(mission)}\n'
                          '${_statusLabel(mission)}',
                        ),
                        isThreeLine: true,
                        trailing:
                            const Icon(Icons.chevron_right_rounded),
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

  Widget _executionModeSelector({required bool enabled}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'balanced',
              icon: Icon(Icons.speed_rounded),
              label: Text('Limite de potência'),
            ),
            ButtonSegment(
              value: 'best_time',
              icon: Icon(Icons.timer_rounded),
              label: Text('Melhor tempo'),
            ),
          ],
          selected: {_strategy},
          onSelectionChanged: enabled
              ? (values) => setState(() => _strategy = values.first)
              : null,
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _strategy == 'best_time'
              ? const Card(
                  key: ValueKey('best-time-info'),
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'Melhor tempo usa toda a potência disponível nas retas e reduz automaticamente nas curvas e na chegada.',
                    ),
                  ),
                )
              : Column(
                  key: const ValueKey('power-limit'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Potência máxima: ${(_throttle * 100).round()}%',
                    ),
                    Slider(
                      value: _throttle,
                      min: 0.15,
                      max: 0.85,
                      divisions: 14,
                      label: '${(_throttle * 100).round()}%',
                      onChanged: enabled
                          ? (value) =>
                              setState(() => _throttle = value)
                          : null,
                    ),
                  ],
                ),
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
    final editable = !executing && !mission.startConfirmed;

    return ListView(
      key: ValueKey('route-preview-${mission.id}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      children: [
        RoutePreviewMap(
          points: points,
          currentPosition: widget.initialPosition,
          strategy: _strategy,
          cruiseThrottle: _effectiveThrottle,
          boatId: mission.boatId,
          height: 370,
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.sailing_rounded),
            title: Text(
              widget.initialPosition == null
                  ? 'GPS atual indisponível'
                  : 'A rota começa onde o barco está',
            ),
            subtitle: const Text(
              'A posição do barco não é salva como waypoint. Ela será recalculada ao vivo antes da largada.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  mission.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _executionModeSelector(enabled: editable),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed:
                      _busy || executing ? null : () => _sendMission(mission),
                  icon: Icon(
                    executing
                        ? Icons.directions_boat_filled_rounded
                        : Icons.send_rounded,
                  ),
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
                  onPressed:
                      _busy ? null : () => _confirmDelete(mission),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Apagar esta rota'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _createView() {
    final center =
        widget.initialPosition ?? const LatLng(-26.3044, -48.8464);
    final routePolylines = buildRoutePowerPolylines(
      waypoints: _points,
      currentPosition: widget.initialPosition,
      strategy: _strategy,
      cruiseThrottle: _effectiveThrottle,
      boatId: widget.boatId,
    );

    return ListView(
      key: const ValueKey('route-create'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
      children: [
        if (widget.initialPosition == null)
          const Card(
            child: ListTile(
              leading: Icon(Icons.gps_off_rounded),
              title: Text('Mapa apenas como referência'),
              subtitle: Text(
                'Sem GPS atual, a largada não aparece agora. Na execução, a rota começará automaticamente onde o barco estiver.',
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Nova rota',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Toque no mapa para marcar somente os destinos. O barco atual é a largada móvel.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Nome da rota'),
                ),
                const SizedBox(height: 14),
                _executionModeSelector(enabled: true),
                const SizedBox(height: 14),
                SizedBox(
                  height: 420,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: ColoredBox(
                      color: const Color(0xFFDDE7EF),
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 16,
                          onTap: (_, point) =>
                              setState(() => _points.add(point)),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName:
                                'br.org.minervanautica.telemetria',
                          ),
                          if (routePolylines.isNotEmpty)
                            PolylineLayer(polylines: routePolylines),
                          MarkerLayer(
                            markers: [
                              ...buildRoutePowerMarkers(
                                waypoints: _points,
                                currentPosition: widget.initialPosition,
                                strategy: _strategy,
                                cruiseThrottle: _effectiveThrottle,
                                boatId: widget.boatId,
                              ),
                              if (widget.initialPosition != null)
                                Marker(
                                  point: center,
                                  width: 54,
                                  height: 54,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF082B5C),
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 3,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.sailing_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              for (var index = 0;
                                  index < _points.length;
                                  index++)
                                Marker(
                                  point: _points[index],
                                  width: 42,
                                  height: 42,
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: index == _points.length - 1
                                          ? const Color(0xFFDC2626)
                                          : const Color(0xFF082B5C),
                                    ),
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
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
                    Expanded(
                      child: Text('${_points.length} destino(s)'),
                    ),
                    TextButton.icon(
                      onPressed: _points.isEmpty
                          ? null
                          : () => setState(() => _points.removeLast()),
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Desfazer'),
                    ),
                    TextButton.icon(
                      onPressed: _points.isEmpty
                          ? null
                          : () => setState(_points.clear),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Limpar'),
                    ),
                  ],
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveDraft,
                  icon: const Icon(Icons.save_rounded),
                  label: Text(
                    _busy ? 'Salvando...' : 'Salvar rota',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
