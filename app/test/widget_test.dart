import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetria_minerva_app/widgets/boat_attitude_view.dart';
import 'package:telemetria_minerva_app/widgets/minerva_logo.dart';

void main() {
  testWidgets('renders the Minerva identity', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: MinervaLogo()))),
    );

    final logo = tester.widget<Image>(find.byType(Image));
    expect(logo.image, isA<AssetImage>());
    expect((logo.image as AssetImage).assetName, 'assets/images/minerva_nautica.png');
    expect(logo.semanticLabel, 'Minerva Náutica');
  });

  testWidgets('loads the bundled 3D attitude mesh', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BoatAttitudeView(yawDeg: 127, rollDeg: 4, pitchDeg: -2),
        ),
      ),
    );

    expect(find.text('ATITUDE 3D · IMU'), findsOneWidget);
    expect(find.textContaining('YAW   127.0°'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Não foi possível carregar o modelo 3D'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
