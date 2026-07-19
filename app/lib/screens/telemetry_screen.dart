import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/boat_attitude_view.dart';
import '../widgets/minerva_logo.dart';
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
  List<LatLng> _trail = const [];
  Object? _error;
  Timer? _timer;
  bool _fetching = false;
  bool _recordingBusy = false;
  int _tick = 0;
  double _recordThrottle = 0.55;
  String _recordStrategy = 'balanced';

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

  Future<void> _load({bool forceTrail = false}) async {
    if (_fetching) return;
    _fetching = true;
    try {
      final telemetry = await widget.client.latest(widget.boatId);
      final recording = await widget.client.activeRecording(widget.boatId);
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
          _trail = trail;
          _error = null;
        });
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

  void _openPlanner() {
    final telemetry = _telemetry;
    final position = telemetry?.latitude != null && telemetry?.longitude != null
        ? LatLng(telemetry!.latitude!, telemetry.longitude!)
        : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MissionPlannerScreen(
          client: widget.client,
          boatId: widget.boatId,
          initialPosition: position,
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_recordingBusy || !widget.profile.isCaptain) return;
    setState(() => _recordingBusy = true);
    try {
      if (_recording == null) {
        final now = DateTime.now();
        await widget.client.startRecording(
          boatId: widget.boatId,
          name: 'Trajetória DUNA ${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          cruiseThrottle: _recordThrottle,
          strategy: _recordStrategy,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gravação iniciada. O backend continuará registrando mesmo com a tela bloqueada.')),
          );
        }
      } else {
        final mission = await widget.client.stopRecording(_recording!.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Trajetória salva como “${mission.name}”.')),
          );
        }
      }
      await _load(forceTrail: true);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha: $error')));
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Widget _motorCard(Telemetry telemetry) {
    final motorOn = telemetry.motorOn;
    final color = motorOn ? const Color(0xFF16A34A) : const Color(0xFF64748B);
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
                key: ValueKey(motorOn),
                color: color,
                size: 34,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(motorOn ? 'MOTOR LIGADO' : 'MOTOR DESLIGADO', style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
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
    final running = armed && latched && telemetry.motorOn;
    final title = running ? 'PILOTO AUTOMÁTICO RODANDO' : latched ? 'PILOTO AUTOMÁTICO LIBERADO' : armed ? 'AUTO ARMADO · AGUARDANDO LATCH' : 'PILOTO AUTOMÁTICO DESARMADO';
    final color = running ? Colors.green : latched ? Colors.blue : armed ? Colors.orange : Colors.blueGrey;
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
        subtitle: Text(latched ? 'O botão do rádio está travado em START.' : 'CH3 em AUTO não liga o motor sozinho. Pressione o botão de latch no rádio.'),
      ),
    );
  }

  Widget _captainControls() {
    final active = _recording != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.workspace_premium_rounded, color: Color(0xFF082B5C)),
                const SizedBox(width: 10),
                Expanded(child: Text('Central do capitão', style: Theme.of(context).textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 8),
            const Text('A gravação acontece no backend da margem. Apenas tokens de capitão podem iniciar, parar ou ativar rotas.'),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'balanced', icon: Icon(Icons.tune_rounded), label: Text('Controle fino')),
                ButtonSegment(value: 'best_time', icon: Icon(Icons.timer_rounded), label: Text('Melhor tempo')),
              ],
              selected: {_recordStrategy},
              onSelectionChanged: active ? null : (values) => setState(() => _recordStrategy = values.first),
            ),
            const SizedBox(height: 16),
            Text('Limite de potência: ${(_recordThrottle * 100).round()}%'),
            Slider(
              value: _recordThrottle,
              min: 0.15,
              max: 0.85,
              divisions: 14,
              label: '${(_recordThrottle * 100).round()}%',
              onChanged: active ? null : (value) => setState(() => _recordThrottle = value),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: active
                        ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700)
                        : null,
                    onPressed: _recordingBusy ? null : _toggleRecording,
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      child: Icon(active ? Icons.stop_rounded : Icons.fiber_manual_record_rounded, key: ValueKey(active)),
                    ),
                    label: Text(_recordingBusy ? 'Processando...' : active ? 'Parar e salvar rota' : 'Gravar trajetória'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(onPressed: _openPlanner, tooltip: 'Planejar e ativar rotas', icon: const Icon(Icons.route_rounded)),
              ],
            ),
            if (active) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(borderRadius: BorderRadius.circular(999)),
              const SizedBox(height: 8),
              Text('${_recording!.points.length} pontos registrados · iniciada ${_recording!.startedAt.toLocal()}'),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = _telemetry;
    final recordingPoints = _recording?.points.map((point) => LatLng(point.latitude, point.longitude)).toList() ?? const <LatLng>[];
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: MinervaAppBarTitle(title: widget.boatId),
        actions: [
          if (widget.profile.isCaptain)
            IconButton(
              onPressed: _recordingBusy ? null : _toggleRecording,
              tooltip: _recording == null ? 'Gravar trajetória' : 'Parar gravação',
              icon: Icon(_recording == null ? Icons.fiber_manual_record_rounded : Icons.stop_circle_rounded, color: _recording == null ? null : Colors.red),
            ),
          IconButton(onPressed: _load, tooltip: 'Atualizar', icon: const Icon(Icons.refresh_rounded)),
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
                  if (widget.profile.isCaptain) ...[_captainControls(), const SizedBox(height: 12)],
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
                            FlutterMap(
                              options: MapOptions(initialCenter: LatLng(telemetry.latitude!, telemetry.longitude!), initialZoom: 16),
                              children: [
                                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'br.org.minervanautica.telemetria'),
                                if (_trail.length > 1)
                                  PolylineLayer(polylines: [Polyline(points: _trail, color: Colors.blueGrey.withValues(alpha: 0.65), strokeWidth: 4)]),
                                if (recordingPoints.length > 1)
                                  PolylineLayer(polylines: [Polyline(points: recordingPoints, color: Colors.redAccent, strokeWidth: 6)]),
                                MarkerLayer(markers: [
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
                                ]),
                              ],
                            ),
                            Positioned(
                              left: 12,
                              top: 12,
                              child: Card(
                                color: const Color(0xE6082147),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                                  child: Text(
                                    'LAT  ${telemetry.latitude!.toStringAsFixed(6)}\nLON ${telemetry.longitude!.toStringAsFixed(6)}\nTEMP ${telemetry.temperatureC?.toStringAsFixed(1) ?? '--'} °C',
                                    style: const TextStyle(fontFamily: 'monospace', color: Colors.white, height: 1.45),
                                  ),
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
                                    child: Row(children: [Icon(Icons.fiber_manual_record, color: Colors.white, size: 14), SizedBox(width: 6), Text('GRAVANDO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1))]),
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
