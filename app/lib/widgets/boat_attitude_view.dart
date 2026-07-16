import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'boat_attitude_web_stub.dart'
    if (dart.library.js_interop) 'boat_attitude_web.dart';

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
  static const String _modelId = 'minerva-tug-attitude';
  WebViewController? _webViewController;

  double get _roll => widget.rollDeg.clamp(-60.0, 60.0).toDouble();
  double get _pitch => widget.pitchDeg.clamp(-45.0, 45.0).toDouble();
  String get _orientation =>
      '${(-_roll).toStringAsFixed(2)}deg ${_pitch.toStringAsFixed(2)}deg 0deg';

  @override
  void didUpdateWidget(covariant BoatAttitudeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rollDeg != widget.rollDeg ||
        oldWidget.pitchDeg != widget.pitchDeg) {
      _updateOrientation();
    }
  }

  void _updateOrientation() {
    final orientation = _orientation;
    updateWebModelOrientation(_modelId, orientation);
    unawaited(_updateMobileOrientation(orientation));
  }

  Future<void> _updateMobileOrientation(String orientation) async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      await controller.runJavaScript(
        'document.getElementById(${jsonEncode(_modelId)})'
        '?.setAttribute("orientation", ${jsonEncode(orientation)});',
      );
    } on Object {
      // A próxima amostra de telemetria tenta novamente se a WebView ainda
      // estiver carregando ou já tiver sido descartada.
    }
  }

  Future<void> _openModelSource(BuildContext context) async {
    var opened = false;
    try {
      opened = await launchUrl(
        BoatAttitudeView._modelSource,
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      opened = false;
    }
    if (!opened && context.mounted) {
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
            Positioned.fill(
              child: ModelViewer(
                key: const ValueKey('minerva-tug-model'),
                id: _modelId,
                src: 'assets/models/minerva_tug.glb',
                alt: 'Modelo 3D do rebocador Minerva',
                backgroundColor: const Color(0xFF05162D),
                loading: Loading.eager,
                reveal: Reveal.auto,
                cameraControls: true,
                disablePan: true,
                autoRotate: false,
                cameraOrbit: '35deg 68deg 135%',
                cameraTarget: '0m 0m 0m',
                fieldOfView: '30deg',
                environmentImage: 'neutral',
                exposure: 1.05,
                shadowIntensity: 0.8,
                shadowSoftness: 0.8,
                interpolationDecay: 80,
                orientation: _orientation,
                debugLogging: false,
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  _updateOrientation();
                },
              ),
            ),
            Positioned(
              left: 14,
              top: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xCC020617),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Text(
                    'ATITUDE 3D · ADXL345',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xCC020617),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Text(
                    'roll ${widget.rollDeg.toStringAsFixed(1)}°  ·  pitch ${widget.pitchDeg.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 6,
              bottom: 2,
              child: TextButton.icon(
                onPressed: () => _openModelSource(context),
                icon: const Icon(Icons.info_outline, size: 16),
                label: const Text('Altug Tuncel · GrabCAD'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  backgroundColor: const Color(0x99020617),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
