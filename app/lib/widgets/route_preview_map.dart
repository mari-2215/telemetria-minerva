import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../models.dart';

class RoutePowerLabel {
  const RoutePowerLabel({
    required this.position,
    required this.text,
    required this.power,
  });

  final LatLng position;
  final String text;
  final double power;
}

bool _isNetuno(String boatId) =>
    boatId.trim().toLowerCase().startsWith('netuno');

List<LatLng> routePathWithCurrent({
  required List<LatLng> waypoints,
  LatLng? currentPosition,
}) {
  if (currentPosition == null) return List<LatLng>.of(waypoints);
  if (waypoints.isEmpty) return [currentPosition];

  final distance = Distance().as(
    LengthUnit.Meter,
    currentPosition,
    waypoints.first,
  );
  if (distance < 0.8) return List<LatLng>.of(waypoints);
  return [currentPosition, ...waypoints];
}

double _bearing(LatLng from, LatLng to) {
  final lat1 = from.latitude * math.pi / 180.0;
  final lat2 = to.latitude * math.pi / 180.0;
  final deltaLon = (to.longitude - from.longitude) * math.pi / 180.0;
  final y = math.sin(deltaLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
  return math.atan2(y, x);
}

double _turnSeverity(
  LatLng previous,
  LatLng point,
  LatLng next,
) {
  var delta = (_bearing(point, next) - _bearing(previous, point)).abs();
  while (delta > math.pi) {
    delta = (2 * math.pi - delta).abs();
  }
  return (delta / math.pi).clamp(0.0, 1.0);
}

bool _isUTurn(
  LatLng previous,
  LatLng point,
  LatLng next,
) =>
    _turnSeverity(previous, point, next) >= 0.82;

double routeMaximumPower(
  String strategy,
  double cruiseThrottle,
) {
  if (strategy == 'best_time') return 1.0;
  return cruiseThrottle.clamp(0.15, 0.85).toDouble();
}

List<double> _nodePowers(
  List<LatLng> path,
  String strategy,
  double cruiseThrottle,
  String boatId, {
  required bool hasLiveStart,
}) {
  if (path.isEmpty) return const [];

  final maximum = routeMaximumPower(
    strategy,
    cruiseThrottle,
  );
  if (path.length == 1) return [hasLiveStart ? 0.0 : maximum];

  final powers = List<double>.filled(path.length, maximum);
  if (hasLiveStart) powers.first = 0.0;
  powers.last = 0.0;

  final penalty = strategy == 'best_time' ? 0.45 : 0.58;
  final minimumMoving =
      math.min(maximum, strategy == 'best_time' ? 0.42 : 0.34);

  for (var index = 1; index < path.length - 1; index++) {
    final severity = _turnSeverity(
      path[index - 1],
      path[index],
      path[index + 1],
    );

    if (severity >= 0.82) {
      powers[index] =
          _isNetuno(boatId) ? 0.0 : math.max(minimumMoving, maximum * 0.45);
      continue;
    }

    final value = maximum * (1.0 - penalty * severity);
    powers[index] = value.clamp(minimumMoving, maximum).toDouble();
  }

  return powers;
}

double _segmentPower(
  int segmentIndex,
  double localProgress,
  List<double> nodePowers,
  double maximum,
) {
  const maneuverZone = 0.20;
  final start = nodePowers[segmentIndex];
  final end = nodePowers[segmentIndex + 1];

  if (localProgress < maneuverZone) {
    final progress = localProgress / maneuverZone;
    return start + (maximum - start) * progress;
  }

  if (localProgress > 1.0 - maneuverZone) {
    final progress = (localProgress - (1.0 - maneuverZone)) / maneuverZone;
    return maximum + (end - maximum) * progress;
  }

  return maximum;
}

Color routePowerColor(
  double power, {
  double maximumPower = 1.0,
}) {
  final normalized = maximumPower <= 0
      ? 0.0
      : (power / maximumPower).clamp(0.0, 1.0).toDouble();

  if (normalized <= 0.5) {
    return Color.lerp(
      const Color(0xFFDC2626),
      const Color(0xFFFACC15),
      normalized * 2,
    )!;
  }

  return Color.lerp(
    const Color(0xFFFACC15),
    const Color(0xFF16A34A),
    (normalized - 0.5) * 2,
  )!;
}

List<Polyline> buildRoutePowerPolylines({
  required List<LatLng> waypoints,
  LatLng? currentPosition,
  required String strategy,
  required double cruiseThrottle,
  String boatId = '',
  double strokeWidth = 6,
  bool dashed = false,
  double opacity = 1.0,
}) {
  final path = routePathWithCurrent(
    waypoints: waypoints,
    currentPosition: currentPosition,
  );
  if (path.length < 2) return const [];

  final maximum = routeMaximumPower(
    strategy,
    cruiseThrottle,
  );
  final nodePowers = _nodePowers(
    path,
    strategy,
    cruiseThrottle,
    boatId,
    hasLiveStart: currentPosition != null,
  );
  final result = <Polyline>[];
  const subdivisions = 24;

  for (var segment = 0; segment < path.length - 1; segment++) {
    final from = path[segment];
    final to = path[segment + 1];

    for (var slice = 0; slice < subdivisions; slice++) {
      if (dashed && slice.isOdd) continue;

      final t0 = slice / subdivisions;
      final t1 = (slice + 1) / subdivisions;

      LatLng interpolate(double t) => LatLng(
            from.latitude + (to.latitude - from.latitude) * t,
            from.longitude + (to.longitude - from.longitude) * t,
          );

      final power = _segmentPower(
        segment,
        (t0 + t1) / 2,
        nodePowers,
        maximum,
      );

      result.add(
        Polyline(
          points: [interpolate(t0), interpolate(t1)],
          color: routePowerColor(
            power,
            maximumPower: maximum,
          ).withValues(alpha: opacity),
          strokeWidth: strokeWidth,
        ),
      );
    }
  }

  return result;
}

List<RoutePowerLabel> buildRoutePowerLabels({
  required List<LatLng> waypoints,
  LatLng? currentPosition,
  required String strategy,
  required double cruiseThrottle,
  String boatId = '',
}) {
  final path = routePathWithCurrent(
    waypoints: waypoints,
    currentPosition: currentPosition,
  );
  if (path.isEmpty) return const [];

  final powers = _nodePowers(
    path,
    strategy,
    cruiseThrottle,
    boatId,
    hasLiveStart: currentPosition != null,
  );
  final labels = <RoutePowerLabel>[];

  if (currentPosition != null) {
    labels.add(
      RoutePowerLabel(
        position: path.first,
        text: 'PARTIDA',
        power: 0,
      ),
    );
  }

  for (var index = 1; index < path.length - 1; index++) {
    final previous = path[index - 1];
    final point = path[index];
    final next = path[index + 1];
    final severity = _turnSeverity(previous, point, next);

    if (_isUTurn(previous, point, next)) {
      labels.add(
        RoutePowerLabel(
          position: point,
          text: _isNetuno(boatId) ? 'PARA + RÉ' : 'GIRO 180°',
          power: powers[index],
        ),
      );
      continue;
    }

    if (severity < 0.22) continue;
    labels.add(
      RoutePowerLabel(
        position: point,
        text: '${(powers[index] * 100).round()}%',
        power: powers[index],
      ),
    );
  }

  labels.add(
    RoutePowerLabel(
      position: path.last,
      text: 'PARADA',
      power: 0,
    ),
  );
  return labels;
}

List<Marker> buildRoutePowerMarkers({
  required List<LatLng> waypoints,
  LatLng? currentPosition,
  required String strategy,
  required double cruiseThrottle,
  String boatId = '',
}) {
  final maximum = routeMaximumPower(
    strategy,
    cruiseThrottle,
  );

  return buildRoutePowerLabels(
    waypoints: waypoints,
    currentPosition: currentPosition,
    strategy: strategy,
    cruiseThrottle: cruiseThrottle,
    boatId: boatId,
  )
      .map(
        (label) => Marker(
          point: label.position,
          width: label.text.length > 5 ? 84 : 54,
          height: 30,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: routePowerColor(
                label.power,
                maximumPower: maximum,
              ).withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white,
                width: 1.5,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 5,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 7,
                vertical: 4,
              ),
              child: Text(
                label.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
      )
      .toList(growable: false);
}

class RoutePreviewMap extends StatelessWidget {
  const RoutePreviewMap({
    super.key,
    required this.points,
    this.currentPosition,
    required this.strategy,
    required this.cruiseThrottle,
    this.boatId = '',
    this.height = 320,
    this.circular = false,
    this.opacity = 1,
    this.showLegend = true,
  });

  final List<LatLng> points;
  final LatLng? currentPosition;
  final String strategy;
  final double cruiseThrottle;
  final String boatId;
  final double height;
  final bool circular;
  final double opacity;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final painted = Opacity(
      opacity: opacity,
      child: CustomPaint(
        painter: _RoutePreviewPainter(
          points: points,
          currentPosition: currentPosition,
          strategy: strategy,
          cruiseThrottle: cruiseThrottle,
          boatId: boatId,
          brightness: Theme.of(context).brightness,
        ),
        child: SizedBox.expand(
          child: points.isEmpty
              ? const Center(
                  child: Text(
                    'Rota sem pontos',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );

    final clipped = circular
        ? ClipOval(child: painted)
        : ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: painted,
          );

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                shape: circular ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: circular ? null : BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.30),
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
            ),
          ),
          if (showLegend && !circular)
            const Positioned(
              left: 14,
              bottom: 12,
              child: _PowerLegend(),
            ),
        ],
      ),
    );
  }
}

class _PowerLegend extends StatelessWidget {
  const _PowerLegend();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9082147),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'POTÊNCIA RELATIVA',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 5),
            Row(
              children: [
                _LegendDot(color: Color(0xFF16A34A)),
                Text(
                  ' máxima',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                  ),
                ),
                SizedBox(width: 8),
                _LegendDot(color: Color(0xFFFACC15)),
                Text(
                  ' reduzindo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                  ),
                ),
                SizedBox(width: 8),
                _LegendDot(color: Color(0xFFDC2626)),
                Text(
                  ' parada',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      );
}

class RouteMiniMap extends StatelessWidget {
  const RouteMiniMap({
    super.key,
    required this.mission,
    this.currentPosition,
    this.liveStart = false,
    this.courseDeg,
  });

  final Mission mission;
  final LatLng? currentPosition;
  final bool liveStart;
  final double? courseDeg;

  @override
  Widget build(BuildContext context) {
    final points = mission.waypoints
        .map(
          (point) => LatLng(
            point.latitude,
            point.longitude,
          ),
        )
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
              currentPosition: liveStart ? currentPosition : null,
              strategy: mission.strategy,
              cruiseThrottle: mission.cruiseThrottle,
              boatId: mission.boatId,
              height: 148,
              circular: true,
              opacity: 0.86,
              showLegend: false,
            ),
            Positioned(
              right: 9,
              top: 9,
              child: _MiniMapCompass(courseDeg: courseDeg),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  child: Text(
                    mission.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
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

class _MiniMapCompass extends StatelessWidget {
  const _MiniMapCompass({required this.courseDeg});

  final double? courseDeg;

  @override
  Widget build(BuildContext context) {
    final heading = (courseDeg ?? 0) % 360;
    return Semantics(
      label: courseDeg == null
          ? 'Bússola: rumo indisponível'
          : 'Bússola: rumo ${heading.round()} graus',
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xE6082147),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 7)],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Positioned(
              top: 2,
              child: Text(
                'N',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Transform.rotate(
              angle: heading * math.pi / 180,
              child: const Icon(
                Icons.navigation_rounded,
                color: Color(0xFFFACC15),
                size: 24,
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
    required this.strategy,
    required this.cruiseThrottle,
    required this.boatId,
    required this.brightness,
  });

  final List<LatLng> points;
  final LatLng? currentPosition;
  final String strategy;
  final double cruiseThrottle;
  final String boatId;
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
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        grid,
      );
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        grid,
      );
    }

    final path = routePathWithCurrent(
      waypoints: points,
      currentPosition: currentPosition,
    );
    if (path.isEmpty) return;

    var minLat = path.first.latitude;
    var maxLat = path.first.latitude;
    var minLon = path.first.longitude;
    var maxLon = path.first.longitude;

    for (final point in path.skip(1)) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLon = math.min(minLon, point.longitude);
      maxLon = math.max(maxLon, point.longitude);
    }

    final latSpan = math.max(maxLat - minLat, 0.00001);
    final lonSpan = math.max(maxLon - minLon, 0.00001);
    final padding = math.min(size.width, size.height) * 0.16;

    Offset project(LatLng point) {
      final usableWidth = math.max(1.0, size.width - padding * 2);
      final usableHeight = math.max(1.0, size.height - padding * 2);
      final x = padding + (point.longitude - minLon) / lonSpan * usableWidth;
      final y = size.height -
          padding -
          (point.latitude - minLat) / latSpan * usableHeight;
      return Offset(x, y);
    }

    if (path.length > 1) {
      final maximum = routeMaximumPower(
        strategy,
        cruiseThrottle,
      );
      final powers = _nodePowers(
        path,
        strategy,
        cruiseThrottle,
        boatId,
        hasLiveStart: currentPosition != null,
      );
      const subdivisions = 24;

      for (var segment = 0; segment < path.length - 1; segment++) {
        final start = project(path[segment]);
        final end = project(path[segment + 1]);

        for (var slice = 0; slice < subdivisions; slice++) {
          final t0 = slice / subdivisions;
          final t1 = (slice + 1) / subdivisions;
          final a = Offset.lerp(start, end, t0)!;
          final b = Offset.lerp(start, end, t1)!;
          final power = _segmentPower(
            segment,
            (t0 + t1) / 2,
            powers,
            maximum,
          );

          canvas.drawLine(
            a,
            b,
            Paint()
              ..color = Colors.black.withValues(alpha: 0.22)
              ..strokeWidth = 9
              ..strokeCap = StrokeCap.round,
          );
          canvas.drawLine(
            a,
            b,
            Paint()
              ..color = routePowerColor(
                power,
                maximumPower: maximum,
              )
              ..strokeWidth = 6
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }

    void drawPoint(
      Offset point,
      Color color,
      double radius,
    ) {
      canvas.drawCircle(
        point,
        radius + 3,
        Paint()..color = Colors.white.withValues(alpha: 0.92),
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()..color = color,
      );
    }

    if (currentPosition != null) {
      drawPoint(
        project(path.first),
        const Color(0xFF082B5C),
        7,
      );
    }

    for (var index = 0; index < points.length; index++) {
      final isLast = index == points.length - 1;
      drawPoint(
        project(points[index]),
        isLast ? const Color(0xFFDC2626) : const Color(0xFF0B6CCB),
        isLast ? 7 : 5,
      );
    }

    final maximum = routeMaximumPower(
      strategy,
      cruiseThrottle,
    );
    final labels = buildRoutePowerLabels(
      waypoints: points,
      currentPosition: currentPosition,
      strategy: strategy,
      cruiseThrottle: cruiseThrottle,
      boatId: boatId,
    );

    for (final label in labels) {
      final center = project(label.position);
      final painter = TextPainter(
        text: TextSpan(
          text: label.text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center.translate(0, -20),
          width: painter.width + 14,
          height: 22,
        ),
        const Radius.circular(999),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = routePowerColor(
            label.power,
            maximumPower: maximum,
          ),
      );
      painter.paint(
        canvas,
        Offset(
          rect.center.dx - painter.width / 2,
          rect.center.dy - painter.height / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant _RoutePreviewPainter oldDelegate,
  ) {
    return oldDelegate.points != points ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.strategy != strategy ||
        oldDelegate.cruiseThrottle != cruiseThrottle ||
        oldDelegate.boatId != boatId ||
        oldDelegate.brightness != brightness;
  }
}
