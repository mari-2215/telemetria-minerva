import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../models.dart';

class RoutePreviewMap extends StatelessWidget {
  const RoutePreviewMap({
    super.key,
    required this.points,
    this.currentPosition,
    this.height = 320,
    this.circular = false,
    this.opacity = 1,
  });

  final List<LatLng> points;
  final LatLng? currentPosition;
  final double height;
  final bool circular;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final painted = Opacity(
      opacity: opacity,
      child: CustomPaint(
        painter: _RoutePreviewPainter(
          points: points,
          currentPosition: currentPosition,
          brightness: Theme.of(context).brightness,
        ),
        child: SizedBox.expand(
          child: points.isEmpty
              ? const Center(
                  child: Text(
                    'Rota sem pontos',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                )
              : null,
        ),
      ),
    );

    final clipped = circular
        ? ClipOval(child: painted)
        : ClipRRect(borderRadius: BorderRadius.circular(24), child: painted);

    return Container(
      height: height,
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.30),
          width: circular ? 3 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.20),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: clipped,
    );
  }
}

class RouteMiniMap extends StatelessWidget {
  const RouteMiniMap({
    super.key,
    required this.mission,
    this.currentPosition,
  });

  final Mission mission;
  final LatLng? currentPosition;

  @override
  Widget build(BuildContext context) {
    final points = mission.waypoints
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);

    return Semantics(
      label: 'Minimapa da rota ${mission.name}',
      child: SizedBox(
        width: 148,
        height: 148,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            RoutePreviewMap(
              points: points,
              currentPosition: currentPosition,
              height: 148,
              circular: true,
              opacity: 0.84,
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xD9082147),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  child: Text(
                    mission.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoutePreviewPainter extends CustomPainter {
  const _RoutePreviewPainter({
    required this.points,
    required this.currentPosition,
    required this.brightness,
  });

  final List<LatLng> points;
  final LatLng? currentPosition;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = dark ? const Color(0xFF07182D) : const Color(0xFFE4EDF5),
    );

    final grid = Paint()
      ..color = dark
          ? Colors.white.withValues(alpha: 0.055)
          : const Color(0xFF082B5C).withValues(alpha: 0.07)
      ..strokeWidth = 1;

    for (var index = 1; index < 6; index++) {
      final x = size.width * index / 6;
      final y = size.height * index / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final north = TextPainter(
      text: TextSpan(
        text: 'N',
        style: TextStyle(
          color: dark ? Colors.white70 : const Color(0xFF082B5C),
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    north.paint(canvas, Offset(size.width / 2 - north.width / 2, 8));

    if (points.isEmpty) return;

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLon = points.first.longitude;
    var maxLon = points.first.longitude;

    for (final point in points.skip(1)) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLon = math.min(minLon, point.longitude);
      maxLon = math.max(maxLon, point.longitude);
    }

    if (currentPosition != null) {
      minLat = math.min(minLat, currentPosition!.latitude);
      maxLat = math.max(maxLat, currentPosition!.latitude);
      minLon = math.min(minLon, currentPosition!.longitude);
      maxLon = math.max(maxLon, currentPosition!.longitude);
    }

    final latSpan = math.max(maxLat - minLat, 0.00001);
    final lonSpan = math.max(maxLon - minLon, 0.00001);
    final padding = math.min(size.width, size.height) * 0.15;

    Offset project(LatLng point) {
      final usableWidth = math.max(1.0, size.width - padding * 2);
      final usableHeight = math.max(1.0, size.height - padding * 2);
      final x = padding + (point.longitude - minLon) / lonSpan * usableWidth;
      final y = size.height - padding - (point.latitude - minLat) / latSpan * usableHeight;
      return Offset(x, y);
    }

    final first = project(points.first);
    final route = Path()..moveTo(first.dx, first.dy);
    for (final point in points.skip(1)) {
      final value = project(point);
      route.lineTo(value.dx, value.dy);
    }

    canvas.drawPath(
      route,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      route,
      Paint()
        ..color = const Color(0xFF22A8F5)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    void drawPoint(Offset point, Color color, double radius) {
      canvas.drawCircle(point, radius + 3, Paint()..color = Colors.white.withValues(alpha: 0.90));
      canvas.drawCircle(point, radius, Paint()..color = color);
    }

    drawPoint(project(points.first), const Color(0xFF16A34A), 6);
    if (points.length > 1) {
      drawPoint(project(points.last), const Color(0xFFEF4444), 6);
    }

    if (currentPosition != null) {
      final current = project(currentPosition!);
      canvas.drawCircle(current, 11, Paint()..color = const Color(0x66082147));
      drawPoint(current, const Color(0xFF082B5C), 5);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePreviewPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.brightness != brightness;
  }
}
