import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/minerva_logo.dart';
import 'manuals_screen.dart';
import 'telemetry_screen.dart';

class FleetScreen extends StatefulWidget {
  const FleetScreen({
    super.key,
    required this.client,
    required this.profile,
    required this.onLogout,
  });

  final ApiClient client;
  final UserProfile profile;
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
        _ => Colors.green,
      };

  @override
  Widget build(BuildContext context) {
    final captain = widget.profile.isCaptain;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 74,
        title: const MinervaAppBarTitle(title: 'Frota'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: captain ? const Color(0xFFE6F0FB) : Colors.white10,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Text(widget.profile.label,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Manuais',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ManualsScreen()),
            ),
            icon: const Icon(Icons.menu_book_rounded),
          ),
          IconButton(
              onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
          IconButton(
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout_rounded)),
          const SizedBox(width: 6),
        ],
      ),
      body: FutureBuilder<List<BoatSummary>>(
        future: _boats,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Falha ao carregar: ${snapshot.error}'));
          }
          final boats = snapshot.data ?? const [];
          if (boats.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sailing_rounded,
                        size: 72, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 18),
                    Text('Aguardando a primeira telemetria',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    const Text(
                        'Assim que o barco transmitir, ele aparece aqui.',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              itemCount: boats.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final boat = boats[index];
                final severity = _severityColor(boat.severity);
                return Hero(
                  tag: 'boat-card-${boat.id}',
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TelemetryScreen(
                              client: widget.client,
                              profile: widget.profile,
                              boatId: boat.id),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 500),
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: severity.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(Icons.directions_boat_filled_rounded,
                                  color: severity, size: 30),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(boat.id,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Último pacote: ${boat.recordedAt.toLocal()}'),
                                  const SizedBox(height: 6),
                                  Text(
                                    boat.severity.toUpperCase(),
                                    style: TextStyle(
                                        color: severity,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.1),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios_rounded,
                                size: 17),
                          ],
                        ),
                      ),
                    ),
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
