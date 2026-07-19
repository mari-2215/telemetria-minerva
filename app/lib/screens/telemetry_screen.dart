import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/boat_attitude_view.dart';
import '../widgets/minerva_logo.dart';
import '../widgets/route_preview_map.dart';
import 'mission_planner_screen.dart';

class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({
    super.key,
    required this.client,
    required this.profile,
    required this.boatId,
  });

  final ApiClient client;
  final UserProfile profile;
  final String boatId;

  @override
  State<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends State<TelemetryScreen> {
  Telemetry? _telemetry;
  RouteRecording? _recording;
  Mission? _mission;
  List<LatLng> _trail = const [];
  Object? _error;
  Timer? _timer;
  bool _fetching = false;
  bool _recordingBusy = false;
  bool _readyDialogOpen = false;
  bool? _lastLatchState;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _load(forceTrail: true);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Mission? _selectMission(List<Mission> missions) {
    for (final desiredStatus in const ['active', 'pending']) {
      for (final mission in missions) {
        if (mission.status == desiredStatus) return mission;
      }
    }
    return null;
  }

  Future<void> _load({bool forceTrail = false}) async {
    if (_fetching) return;
    _fetching = true;
    try {
      final telemetry = await widget.client.latest(widget.boatId);
      final recording = await widget.client.activeRecording(widget.boatId);
      final missions = await widget.client.missions(widget.boatId);
      final mission = _selectMission(missions);
      final previousLatch = _lastLatchState;
      var trail = _trail;
      _tick += 1;
      if (forceTrail || _tick % 5 == 0) {
        final samples = await widget.client.samples(widget.boatId, limit: 240);
        trail = samples
            .where((sample) => sample.latitude != null && sample.longitude != null)
            .map((sample) => LatLng(sample.latitude!, sample.longitude!))
            .toList(growable: false);
      }
      if (mounted) {
        setState(() {
          _telemetry = telemetry;
          _recording = recording;
          _mission = mission;
          _lastLatchState = telemetry.autopilotLatched;
          _trail = trail;
          _error = null;
        });
        await _handleLatchTransition(previousLatch, telemetry.autopilotLatched, mission);
      }
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
          padding: const EdgeInsets.all(15),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 9),
              FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleLarge)),
              const SizedBox(height: 2),
              Text(label, textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Future<void> _openPlanner() async {
    final telemetry = _telemetry;
    final position = telemetry?.latitude != null && telemetry?.longitude != null
        ? LatLng(telemetry!.latitude!, telemetry.longitude!)
        : null;
    final sent = await Navigator.of(context).push<Mission>(
      MaterialPageRoute(
        builder: (_) => MissionPlannerScreen(
          client: widget.client,
          boatId: widget.boatId,
          initialPosition: position,
        ),
      ),
    );
    if (sent == null || !mounted) return;

    setState(() => _mission = sent);
    final latchAlreadyOn = _telemetry?.autopilotLatched == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF15803D),
        content: Text(
          latchAlreadyOn
              ? 'Rota “${sent.name}” enviada. Desligue e acione o latch novamente para autorizar.'
              : 'Rota “${sent.name}” enviada com sucesso.',
        ),
      ),
    );
    await _load();
  }

  Future<void> _handleLatchTransition(
    bool? previous,
    bool latched,
    Mission? mission,
  ) async {
    if (!widget.profile.isCaptain) return;

    if (previous == true &&
        !latched &&
        mission != null &&
        mission.startConfirmed) {
      try {
        final updated =
            await widget.client.setMissionReady(mission.id, false);
        if (mounted) setState(() => _mission = updated);
      } catch (_) {
        // O backend e o Raspberry também revogam a autorização.
      }
      return;
    }

    // Somente uma transição observada de OFF para ON abre a confirmação.
    if (previous == false && latched) {
      if (mission == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Latch acionado, mas nenhuma rota foi enviada ao barco.',
            ),
          ),
        );
        return;
      }
      if (!mission.startConfirmed) await _askBoatReady(mission);
    }
  }

  Future<void> _askBoatReady(Mission mission) async {
    if (_readyDialogOpen || !mounted || !widget.profile.isCaptain) return;
    _readyDialogOpen = true;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.health_and_safety_rounded, size: 42),
        title: const Text('Confirmar início automático'),
        content: Text(
          'O latch do rádio foi acionado.\n\n'
          'O barco está pronto para iniciar a trajetória automática “${mission.name}”?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Ainda não'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Sim, iniciar'),
          ),
        ],
      ),
    );
    _readyDialogOpen = false;
    if (!mounted) return;

    if (confirmed != true) {
      try {
        final updated = await widget.client.setMissionReady(mission.id, false);
        if (mounted) setState(() => _mission = updated);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Partida automática não autorizada. O motor permanece parado.')),
        );
      }
      return;
    }

    final telemetry = _telemetry;
    if (telemetry?.autopilotLatched != true ||
        telemetry?.controlMode != 'auto' ||
        telemetry?.rcHealthy != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'O rádio saiu do estado seguro antes da confirmação.',
          ),
        ),
      );
      return;
    }
    if (telemetry?.latitude == null || telemetry?.longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Aguardando posição GPS válida. A rota só começa de onde o barco está.',
          ),
        ),
      );
      return;
    }

    try {
      final updated = await widget.client.setMissionReady(mission.id, true);
      if (mounted) setState(() => _mission = updated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF15803D),
            content: Text('Barco confirmado como pronto. Partida automática autorizada.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível autorizar a partida: $error')),
        );
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_recordingBusy || !widget.profile.isCaptain) return;
    setState(() => _recordingBusy = true);
    try {
      if (_recording == null) {
        final now = DateTime.now();
        await widget.client.startRecording(
          boatId: widget.boatId,
          name:
              'Trajetória DUNA ${now.day.toString().padLeft(2, '0')}-'
              '${now.month.toString().padLeft(2, '0')} '
              '${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')}',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Gravação iniciada. Apenas a trajetória GPS será registrada.',
              ),
            ),
          );
        }
      } else {
        final mission =
            await widget.client.stopRecording(_recording!.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Trajetória salva como “${mission.name}”. '
                'Escolha o modo de potência ao enviar a rota.',
              ),
            ),
          );
        }
      }
      await _load(forceTrail: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Widget _motorCard(Telemetry telemetry) {
    final motorOn = telemetry.motorOn;
    final unauthorized = motorOn && _mission != null && !_mission!.startConfirmed;
    final color = unauthorized
        ? const Color(0xFFDC2626)
        : motorOn
            ? const Color(0xFF16A34A)
            : const Color(0xFF64748B);
    final title = unauthorized
        ? 'MOTOR LIGADO SEM AUTORIZAÇÃO'
        : motorOn
            ? 'MOTOR LIGADO'
            : 'MOTOR DESLIGADO';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: color.withValues(alpha: Theme.of(context).brightness == Brightness.light ? 0.10 : 0.18),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        boxShadow: motorOn ? [BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 24, spreadRadius: 2)] : const [],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, animation) => RotationTransition(
                turns: Tween<double>(begin: 0.85, end: 1).animate(animation),
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: Icon(
                motorOn ? Icons.power_rounded : Icons.power_off_rounded,
                key: ValueKey('$motorOn-$unauthorized'),
                color: color,
                size: 34,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                  const SizedBox(height: 3),
                  Text('ESC ${_number(telemetry.propulsion, 'esc_pwm_us', 'µs', decimals: 0)} · Potência ${_number(telemetry.propulsion, 'throttle_norm', '', decimals: 2)}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _autopilotCard(Telemetry telemetry) {
    final armed = telemetry.autopilotArmed;
    final latched = telemetry.autopilotLatched;
    final authorized = _mission?.startConfirmed ?? false;
    final running = armed && latched && authorized && telemetry.motorOn;
    final title = running
        ? 'PILOTO AUTOMÁTICO RODANDO'
        : latched && !authorized
            ? 'LATCH ACIONADO · AGUARDANDO CAPITÃO'
            : latched
                ? 'PARTIDA AUTOMÁTICA AUTORIZADA'
                : armed
                    ? 'AUTO ARMADO · AGUARDANDO LATCH'
                    : 'PILOTO AUTOMÁTICO DESARMADO';
    final color = running
        ? Colors.green
        : latched && !authorized
            ? Colors.orange
            : latched
                ? Colors.blue
                : armed
                    ? Colors.orange
                    : Colors.blueGrey;

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        leading: AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(16)),
          child: Icon(running ? Icons.auto_mode_rounded : Icons.shield_outlined, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          latched && !authorized
              ? 'Confirme no app que o barco está pronto. Sem confirmação, o motor permanece parado.'
              : latched
                  ? 'Latch e confirmação do capitão estão ativos.'
                  : 'CH3 em AUTO não liga o motor sozinho. Pressione o botão de latch no rádio.',
        ),
      ),
    );
  }

  Widget _captainActions() {
    final active = _recording != null;

    Widget recordButton() => FilledButton.icon(
          style: active
              ? FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                )
              : null,
          onPressed: _recordingBusy ? null : _toggleRecording,
          icon: Icon(
            active
                ? Icons.stop_rounded
                : Icons.fiber_manual_record_rounded,
          ),
          label: Text(
            _recordingBusy
                ? 'Processando...'
                : active
                    ? 'Parar e salvar rota'
                    : 'Gravar rota',
          ),
        );

    Widget selectButton() => OutlinedButton.icon(
          onPressed: _openPlanner,
          icon: const Icon(Icons.route_rounded),
          label: const Text('Selecionar rota'),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 430) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  recordButton(),
                  const SizedBox(height: 10),
                  selectButton(),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: recordButton()),
                const SizedBox(width: 10),
                Expanded(child: selectButton()),
              ],
            );
          },
        ),
        if (active) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 7),
          Text(
            '${_recording!.points.length} pontos gravados',
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = _telemetry;
    final recordingPoints = _recording?.points.map((point) => LatLng(point.latitude, point.longitude)).toList() ?? const <LatLng>[];
    final missionPoints = _mission?.waypoints.map((point) => LatLng(point.latitude, point.longitude)).toList() ?? const <LatLng>[];
    final currentPosition = telemetry?.latitude != null && telemetry?.longitude != null
        ? LatLng(telemetry!.latitude!, telemetry.longitude!)
        : null;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: MinervaAppBarTitle(title: widget.boatId),
        actions: [
          IconButton(
            onPressed: _load,
            tooltip: 'Atualizar',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: telemetry == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text('Falha: $_error'))
          : RefreshIndicator(
              onRefresh: () => _load(forceTrail: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 34),
                children: [
                  if (telemetry.alarms.isNotEmpty)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_rounded),
                        title: const Text('Alarmes ativos'),
                        subtitle: Text(telemetry.alarms.join(', ')),
                      ),
                    ),
                  _motorCard(telemetry),
                  const SizedBox(height: 12),
                  _autopilotCard(telemetry),
                  const SizedBox(height: 12),
                  if (widget.profile.isCaptain) ...[_captainActions(), const SizedBox(height: 12)],
                  GridView.count(
                    crossAxisCount: MediaQuery.sizeOf(context).width > 700 ? 4 : 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 1.35,
                    children: [
                      _metric('Bateria', _number(telemetry.power, 'battery_v', 'V'), Icons.battery_charging_full_rounded),
                      _metric('Corrente', _number(telemetry.power, 'current_a', 'A'), Icons.electric_bolt_rounded),
                      _metric('Velocidade', _number(telemetry.position, 'speed_mps', 'm/s'), Icons.speed_rounded),
                      _metric('Ângulo do pod', _number(telemetry.propulsion, 'pod_angle_deg', 'graus'), Icons.navigation_rounded),
                      _metric('Temperatura', _number(telemetry.environment, 'electronics_temp_c', '°C'), Icons.thermostat_rounded),
                      _metric('Modo', telemetry.controlMode.toUpperCase(), Icons.tune_rounded),
                    ],
                  ),
                  const SizedBox(height: 12),
                  BoatAttitudeView(yawDeg: telemetry.yawDeg, pitchDeg: telemetry.pitchDeg, rollDeg: telemetry.rollDeg),
                  const SizedBox(height: 12),
                  if (telemetry.latitude != null && telemetry.longitude != null)
                    SizedBox(
                      height: 430,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Stack(
                          children: [
                            ColoredBox(
                              color: const Color(0xFFDDE7EF),
                              child: FlutterMap(
                                options: MapOptions(
                                  initialCenter: LatLng(telemetry.latitude!, telemetry.longitude!),
                                  initialZoom: 16,
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName: 'br.org.minervanautica.telemetria',
                                  ),
                                  if (_trail.length > 1)
                                    PolylineLayer(
                                      polylines: [
                                        Polyline(
                                          points: _trail,
                                          color: Colors.blueGrey.withValues(alpha: 0.65),
                                          strokeWidth: 4,
                                        ),
                                      ],
                                    ),
                                  if (missionPoints.isNotEmpty)
                                    PolylineLayer(
                                      polylines: buildRoutePowerPolylines(
                                        waypoints: missionPoints,
                                        currentPosition: currentPosition,
                                        strategy: _mission!.strategy,
                                        cruiseThrottle: _mission!.cruiseThrottle,
                                        strokeWidth: 6,
                                      ),
                                    ),
                                  if (recordingPoints.length > 1)
                                    PolylineLayer(
                                      polylines: [
                                        Polyline(points: recordingPoints, color: Colors.redAccent, strokeWidth: 6),
                                      ],
                                    ),
                                  MarkerLayer(
                                    markers: [
                                      if (_mission != null)
                                        ...buildRoutePowerMarkers(
                                          waypoints: missionPoints,
                                          currentPosition: currentPosition,
                                          strategy: _mission!.strategy,
                                          cruiseThrottle: _mission!.cruiseThrottle,
                                        ),
                                      Marker(
                                        point: LatLng(telemetry.latitude!, telemetry.longitude!),
                                        width: 58,
                                        height: 58,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: const Color(0xFF082B5C),
                                            border: Border.all(color: Colors.white, width: 3),
                                            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black38)],
                                          ),
                                          child: const Icon(Icons.sailing_rounded, size: 35, color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              left: 12,
                              top: 12,
                              child: Card(
                                color: const Color(0xE6082147),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                                  child: Text(
                                    'LAT  ${telemetry.latitude!.toStringAsFixed(6)}\n'
                                    'LON ${telemetry.longitude!.toStringAsFixed(6)}\n'
                                    'TEMP ${telemetry.temperatureC?.toStringAsFixed(1) ?? '--'} °C',
                                    style: const TextStyle(fontFamily: 'monospace', color: Colors.white, height: 1.45),
                                  ),
                                ),
                              ),
                            ),
                            if (_mission != null)
                              Positioned(
                                right: 14,
                                bottom: 14,
                                child: GestureDetector(
                                  onTap: _openPlanner,
                                  child: RouteMiniMap(
                                    mission: _mission!,
                                    currentPosition: currentPosition,
                                  ),
                                ),
                              ),
                            if (_recording != null)
                              Positioned(
                                right: 12,
                                top: 12,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(999)),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    child: Row(
                                      children: [
                                        Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
                                        SizedBox(width: 6),
                                        Text(
                                          'GRAVANDO',
                                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.gps_off_rounded),
                        title: Text('GPS sem posição válida'),
                        subtitle: Text('O mapa e a gravação aparecem assim que o NEO-6M obtiver fix.'),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    'Pacote ${telemetry.sequence} · ${telemetry.recordedAt.toLocal()}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
    );
  }
}
