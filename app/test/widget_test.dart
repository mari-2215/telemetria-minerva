import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetria_minerva_app/widgets/minerva_logo.dart';

void main() {
  testWidgets('renders the Minerva identity', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: MinervaLogo()))),
    );

    expect(find.text('MINERVA'), findsOneWidget);
    expect(find.text('NAUTICA'), findsOneWidget);
    expect(find.byIcon(Icons.sailing), findsOneWidget);
  });
}
