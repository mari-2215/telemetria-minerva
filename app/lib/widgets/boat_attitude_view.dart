import 'dart:math' as math;

import 'package:flutter/material.dart';

class BoatAttitudeView extends StatelessWidget {
  const BoatAttitudeView({super.key, required this.rollDeg, required this.pitchDeg});
  final double rollDeg;
  final double pitchDeg;

  @override
  Widget build(BuildContext context) {
    final roll = rollDeg.clamp(-35.0, 35.0).toDouble() * math.pi / 180;
    final pitch = pitchDeg.clamp(-25.0, 25.0).toDouble() * math.pi / 180;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        height: 210,
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0C4A6E), Color(0xFF020617)]),
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _WaterPainter())),
            Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateX(pitch)
                  ..rotateZ(-roll),
                child: const SizedBox(width: 230, height: 130, child: CustomPaint(painter: _BoatPainter())),
              ),
            ),
            Positioned(
              left: 14,
              top: 12,
              child: Text('ATITUDE 3D · ADXL345', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white70, fontWeight: FontWeight.bold)),
            ),
            Positioned(
              right: 14,
              bottom: 10,
              child: Text('roll ${rollDeg.toStringAsFixed(1)}°  ·  pitch ${pitchDeg.toStringAsFixed(1)}°', style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaterPainter extends CustomPainter {
  const _WaterPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x5538BDF8)..style = PaintingStyle.stroke..strokeWidth = 1.5;
    for (double y = 120; y < size.height; y += 18) {
      final path = Path()..moveTo(0, y);
      for (double x = 0; x <= size.width; x += 36) {
        path.quadraticBezierTo(x + 9, y - 4, x + 18, y);
        path.quadraticBezierTo(x + 27, y + 4, x + 36, y);
      }
      canvas.drawPath(path, paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BoatPainter extends CustomPainter {
  const _BoatPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final hull = Path()
      ..moveTo(14, 66)
      ..quadraticBezierTo(size.width / 2, 118, size.width - 12, 56)
      ..lineTo(size.width - 42, 91)
      ..quadraticBezierTo(size.width / 2, 132, 36, 92)
      ..close();
    canvas.drawShadow(hull, Colors.black, 12, true);
    canvas.drawPath(hull, Paint()..shader = const LinearGradient(colors: [Color(0xFF020617), Color(0xFF334155)]).createShader(Offset.zero & size));
    final deck = Path()
      ..moveTo(40, 64)
      ..lineTo(size.width - 36, 58)
      ..lineTo(size.width - 62, 79)
      ..lineTo(65, 84)
      ..close();
    canvas.drawPath(deck, Paint()..color = const Color(0xFFE2E8F0));
    final cabin = RRect.fromRectAndRadius(Rect.fromLTWH(84, 30, 82, 42), const Radius.circular(10));
    canvas.drawRRect(cabin, Paint()..color = const Color(0xFF0F172A));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(97, 37, 55, 20), const Radius.circular(5)), Paint()..color = const Color(0xFF38BDF8));
    canvas.drawCircle(Offset(size.width - 46, 72), 7, Paint()..color = const Color(0xFF0EA5E9));
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
