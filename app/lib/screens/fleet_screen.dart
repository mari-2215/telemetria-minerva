import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/minerva_logo.dart';
import 'telemetry_screen.dart';

class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key, required this.client, required this.onLogout});
  final ApiClient client;
  final Future<void> Function() onLogout;

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  late Future<List<BoatSummary>> _boats = widget.client.boats();

  void _refresh() => setState(() => _boats = widget.client.boats());

  Color _severityColor(String severity) => switch (severity) {
        'critical' => Colors.redAccent,
        'warning' => Colors.amber,
        _ => Colors.greenAccent,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const MinervaLogo(compact: true),
        actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)), IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout))],
      ),
      body: FutureBuilder<List<BoatSummary>>(
        future: _boats,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text('Falha ao carregar: ${snapshot.error}'));
          final boats = snapshot.data ?? const [];
          if (boats.isEmpty) return const Center(child: Text('Nenhuma embarcacao enviou telemetria ainda.'));
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: boats.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final boat = boats[index];
                return Card(
                  child: ListTile(
                    leading: Icon(Icons.directions_boat, color: _severityColor(boat.severity)),
                    title: Text(boat.id),
                    subtitle: Text('Ultimo pacote: ${boat.recordedAt.toLocal()}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TelemetryScreen(client: widget.client, boatId: boat.id))),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
