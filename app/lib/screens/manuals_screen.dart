import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/minerva_logo.dart';

enum _ManualBoat { azimutal, netuno }

enum _ManualKind { procedures, conservation }

class ManualsScreen extends StatefulWidget {
  const ManualsScreen({super.key});

  @override
  State<ManualsScreen> createState() => _ManualsScreenState();
}

class _ManualsScreenState extends State<ManualsScreen> {
  _ManualBoat _boat = _ManualBoat.azimutal;
  _ManualKind _kind = _ManualKind.procedures;

  String get _assetPath {
    final boat = _boat == _ManualBoat.azimutal ? 'azimutal' : 'netuno';
    final kind =
        _kind == _ManualKind.procedures ? 'procedimentos' : 'conservacao';
    return 'assets/manuals/$boat-$kind.md';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: const MinervaAppBarTitle(title: 'Manuais de bordo'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 36),
        children: [
          SegmentedButton<_ManualBoat>(
            segments: const [
              ButtonSegment(
                value: _ManualBoat.azimutal,
                icon: Icon(Icons.rotate_right_rounded),
                label: Text('Azimutal'),
              ),
              ButtonSegment(
                value: _ManualBoat.netuno,
                icon: Icon(Icons.sailing_rounded),
                label: Text('Netuno'),
              ),
            ],
            selected: {_boat},
            onSelectionChanged: (values) =>
                setState(() => _boat = values.first),
          ),
          const SizedBox(height: 10),
          SegmentedButton<_ManualKind>(
            segments: const [
              ButtonSegment(
                value: _ManualKind.procedures,
                icon: Icon(Icons.checklist_rounded),
                label: Text('Procedimentos'),
              ),
              ButtonSegment(
                value: _ManualKind.conservation,
                icon: Icon(Icons.build_circle_outlined),
                label: Text('Conservação'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (values) =>
                setState(() => _kind = values.first),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FutureBuilder<String>(
                key: ValueKey(_assetPath),
                future: rootBundle.loadString(_assetPath),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return Text('Falha ao abrir o manual: ${snapshot.error}');
                  }
                  return _ManualDocument(text: snapshot.data ?? '');
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualDocument extends StatelessWidget {
  const _ManualDocument({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trimRight();

      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 10));
      } else if (line.startsWith('# ')) {
        widgets.add(
          Text(line.substring(2),
              style: Theme.of(context).textTheme.headlineSmall),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(line.substring(3),
                style: Theme.of(context).textTheme.titleLarge),
          ),
        );
      } else if (line.startsWith('### ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(line.substring(4),
                style: Theme.of(context).textTheme.titleMedium),
          ),
        );
      } else if (line.startsWith('> ')) {
        widgets.add(
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .errorContainer
                  .withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(line.substring(2)),
          ),
        );
      } else if (line.startsWith('- ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Icon(Icons.circle, size: 7),
                ),
                const SizedBox(width: 10),
                Expanded(child: SelectableText(line.substring(2))),
              ],
            ),
          ),
        );
      } else {
        final numbered = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(line);
        if (numbered != null) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      numbered.group(1)!,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: SelectableText(numbered.group(2)!)),
                ],
              ),
            ),
          );
        } else {
          widgets.add(SelectableText(line));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }
}
