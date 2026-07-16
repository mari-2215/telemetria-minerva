import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class BoatAttitudeView extends StatefulWidget {
  const BoatAttitudeView({
    super.key,
    required this.rollDeg,
    required this.pitchDeg,
  });

  static final Uri _modelSource =
      Uri.parse('https://grabcad.com/library/mini-10-tugboat-1');

  final double rollDeg;
  final double pitchDeg;

  @override
  State<BoatAttitudeView> createState() => _BoatAttitudeViewState();
}

class _BoatAttitudeViewState extends State<BoatAttitudeView> {
  late final Future<_BoatMesh> _mesh;
  double _viewYawDeg = 38;

  @override
  void initState() {
    super.initState();
    _mesh = _BoatMesh.load('assets/models/minerva_tug.mesh');
  }

  Future<void> _openModelSource() async {
    var opened = false;
    try {
      opened = await launchUrl(
        BoatAttitudeView._modelSource,
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o GrabCAD.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 360,
        child: Stack(
          children: [
            const Positioned.fill(child: _AttitudeBackground()),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  setState(() => _viewYawDeg += details.delta.dx * 0.6);
                },
                onDoubleTap: () => setState(() => _viewYawDeg = 38),
                child: FutureBuilder<_BoatMesh>(
                  future: _mesh,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const _MeshError();
                    }
                    final mesh = snapshot.data;
                    if (mesh == null) {
                      return const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    }
                    return CustomPaint(
                      painter: _BoatMeshPainter(
                        mesh: mesh,
                        rollDeg: widget.rollDeg,
                        pitchDeg: widget.pitchDeg,
                        viewYawDeg: _viewYawDeg,
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              left: 14,
              top: 12,
              child: _PanelLabel(
                child: const Text(
                  'ATITUDE 3D · ADXL345',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 14,
              top: 12,
              child: _PanelLabel(
                child: Text(
                  'R ${widget.rollDeg.toStringAsFixed(1)}°\nP ${widget.pitchDeg.toStringAsFixed(1)}°',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            Positioned(
              left: 6,
              bottom: 2,
              child: TextButton.icon(
                onPressed: _openModelSource,
                icon: const Icon(Icons.info_outline, size: 16),
                label: const Text('Altug Tuncel · GrabCAD'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  backgroundColor: const Color(0x99020617),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            const Positioned(
              right: 14,
              bottom: 12,
              child: Text(
                'arraste · 2× centraliza',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC020617),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: child,
      ),
    );
  }
}

class _AttitudeBackground extends StatelessWidget {
  const _AttitudeBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.15),
          radius: 1.05,
          colors: [Color(0xFF123D6A), Color(0xFF050A2B), Color(0xFF020617)],
        ),
      ),
    );
  }
}

class _MeshError extends StatelessWidget {
  const _MeshError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: Colors.white70, size: 40),
          SizedBox(height: 8),
          Text('Não foi possível carregar o modelo 3D',
              style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _BoatMesh {
  const _BoatMesh(this.positions, this.triangles);

  final Float32List positions;
  final Uint32List triangles;

  static Future<_BoatMesh> load(String asset) async {
    final data = await rootBundle.load(asset);
    if (data.lengthInBytes < 16 ||
        String.fromCharCodes(
              List.generate(4, (index) => data.getUint8(index)),
            ) !=
            'M3D1') {
      throw const FormatException('Cabeçalho da malha 3D inválido');
    }

    final version = data.getUint32(4, Endian.little);
    final vertexCount = data.getUint32(8, Endian.little);
    final triangleCount = data.getUint32(12, Endian.little);
    final expectedLength = 16 + vertexCount * 12 + triangleCount * 12;
    if (version != 1 || expectedLength != data.lengthInBytes) {
      throw const FormatException('Tamanho da malha 3D inválido');
    }

    final positions = Float32List(vertexCount * 3);
    var offset = 16;
    for (var index = 0; index < positions.length; index++) {
      positions[index] = data.getFloat32(offset, Endian.little);
      offset += 4;
    }

    final triangles = Uint32List(triangleCount * 3);
    for (var index = 0; index < triangles.length; index++) {
      final vertex = data.getUint32(offset, Endian.little);
      if (vertex >= vertexCount) {
        throw const FormatException('Índice da malha 3D inválido');
      }
      triangles[index] = vertex;
      offset += 4;
    }
    return _BoatMesh(positions, triangles);
  }
}

class _BoatMeshPainter extends CustomPainter {
  const _BoatMeshPainter({
    required this.mesh,
    required this.rollDeg,
    required this.pitchDeg,
    required this.viewYawDeg,
  });

  final _BoatMesh mesh;
  final double rollDeg;
  final double pitchDeg;
  final double viewYawDeg;

  static double _radians(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    _drawReferenceGrid(canvas, size);

    final roll = _radians(rollDeg.clamp(-60, 60).toDouble());
    final pitch = _radians(pitchDeg.clamp(-45, 45).toDouble());
    final yaw = _radians(viewYawDeg);
    const viewTilt = -0.22;
    final sinRoll = math.sin(-roll);
    final cosRoll = math.cos(-roll);
    final sinPitch = math.sin(pitch);
    final cosPitch = math.cos(pitch);
    final sinYaw = math.sin(yaw);
    final cosYaw = math.cos(yaw);
    final sinTilt = math.sin(viewTilt);
    final cosTilt = math.cos(viewTilt);

    final vertexCount = mesh.positions.length ~/ 3;
    final transformed = Float64List(vertexCount * 3);
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;

    for (var vertex = 0; vertex < vertexCount; vertex++) {
      final source = vertex * 3;
      final x = mesh.positions[source];
      final y = mesh.positions[source + 1];
      final z = mesh.positions[source + 2];

      final pitchY = y * cosPitch - z * sinPitch;
      final pitchZ = y * sinPitch + z * cosPitch;
      final rollX = x * cosRoll - pitchY * sinRoll;
      final rollY = x * sinRoll + pitchY * cosRoll;
      final yawX = rollX * cosYaw + pitchZ * sinYaw;
      final yawZ = -rollX * sinYaw + pitchZ * cosYaw;
      final finalY = rollY * cosTilt - yawZ * sinTilt;
      final finalZ = rollY * sinTilt + yawZ * cosTilt;

      transformed[source] = yawX;
      transformed[source + 1] = finalY;
      transformed[source + 2] = finalZ;
      minX = math.min(minX, yawX).toDouble();
      maxX = math.max(maxX, yawX).toDouble();
      minY = math.min(minY, finalY).toDouble();
      maxY = math.max(maxY, finalY).toDouble();
    }

    final modelWidth = math.max(maxX - minX, 0.001).toDouble();
    final modelHeight = math.max(maxY - minY, 0.001).toDouble();
    final scale = math.min(size.width * 0.82 / modelWidth,
        size.height * 0.67 / modelHeight).toDouble();
    final centerX = size.width / 2 - (minX + maxX) * scale / 2;
    final centerY = size.height / 2 + 8 + (minY + maxY) * scale / 2;
    final screenX = Float64List(vertexCount);
    final screenY = Float64List(vertexCount);
    for (var vertex = 0; vertex < vertexCount; vertex++) {
      final source = vertex * 3;
      screenX[vertex] = centerX + transformed[source] * scale;
      screenY[vertex] = centerY - transformed[source + 1] * scale;
    }

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height * 0.73),
        width: size.width * 0.55,
        height: 28,
      ),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    final projected = <_ProjectedTriangle>[];
    for (var offset = 0; offset < mesh.triangles.length; offset += 3) {
      final a = mesh.triangles[offset];
      final b = mesh.triangles[offset + 1];
      final c = mesh.triangles[offset + 2];
      final ax = transformed[a * 3];
      final ay = transformed[a * 3 + 1];
      final az = transformed[a * 3 + 2];
      final bx = transformed[b * 3];
      final by = transformed[b * 3 + 1];
      final bz = transformed[b * 3 + 2];
      final cx = transformed[c * 3];
      final cy = transformed[c * 3 + 1];
      final cz = transformed[c * 3 + 2];

      final ux = bx - ax;
      final uy = by - ay;
      final uz = bz - az;
      final vx = cx - ax;
      final vy = cy - ay;
      final vz = cz - az;
      final nx = uy * vz - uz * vy;
      final ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      final normalLength = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (normalLength < 1e-9) continue;

      final area = (screenX[b] - screenX[a]) * (screenY[c] - screenY[a]) -
          (screenY[b] - screenY[a]) * (screenX[c] - screenX[a]);
      if (area.abs() < 0.08) continue;

      final light = ((nx * -0.34 + ny * 0.78 + nz * 0.53) / normalLength)
          .abs();
      final brightness = 0.34 + 0.66 * light;
      final red = (32 * brightness + 8).clamp(0, 255).round();
      final green = (168 * brightness + 10).clamp(0, 255).round();
      final blue = (238 * brightness + 14).clamp(0, 255).round();
      final color =
          (0xFF000000 | red << 16 | green << 8 | blue).toSigned(32);
      projected.add(
        _ProjectedTriangle(a, b, c, (az + bz + cz) / 3, color),
      );
    }
    projected.sort((left, right) => left.depth.compareTo(right.depth));

    final positions = Float32List(projected.length * 6);
    final colors = Int32List(projected.length * 3);
    for (var index = 0; index < projected.length; index++) {
      final triangle = projected[index];
      final positionOffset = index * 6;
      positions[positionOffset] = screenX[triangle.a];
      positions[positionOffset + 1] = screenY[triangle.a];
      positions[positionOffset + 2] = screenX[triangle.b];
      positions[positionOffset + 3] = screenY[triangle.b];
      positions[positionOffset + 4] = screenX[triangle.c];
      positions[positionOffset + 5] = screenY[triangle.c];
      final colorOffset = index * 3;
      colors[colorOffset] = triangle.color;
      colors[colorOffset + 1] = triangle.color;
      colors[colorOffset + 2] = triangle.color;
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
    );
    canvas.drawVertices(
      vertices,
      BlendMode.dst,
      Paint()..isAntiAlias = true,
    );
  }

  void _drawReferenceGrid(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 10);
    final radius = math.min(size.width, size.height).toDouble() * 0.36;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, radius, paint);
    canvas.drawCircle(center, radius * 0.68, paint);
    canvas.drawLine(
        Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), paint);
    canvas.drawLine(
        Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), paint);
  }

  @override
  bool shouldRepaint(covariant _BoatMeshPainter oldDelegate) {
    return oldDelegate.mesh != mesh ||
        oldDelegate.rollDeg != rollDeg ||
        oldDelegate.pitchDeg != pitchDeg ||
        oldDelegate.viewYawDeg != viewYawDeg;
  }
}

class _ProjectedTriangle {
  const _ProjectedTriangle(this.a, this.b, this.c, this.depth, this.color);

  final int a;
  final int b;
  final int c;
  final double depth;
  final int color;
}
