import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
