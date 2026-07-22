import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../qr_login.dart';
import '../widgets/minerva_logo.dart';

class QrLoginScannerScreen extends StatefulWidget {
  const QrLoginScannerScreen({super.key});

  @override
  State<QrLoginScannerScreen> createState() => _QrLoginScannerScreenState();
}

class _QrLoginScannerScreenState extends State<QrLoginScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;

      try {
        final login = MinervaLoginQr.parse(raw);
        _handled = true;
        Navigator.of(context).pop(login);
        return;
      } on FormatException catch (error) {
        if (mounted) setState(() => _error = error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const MinervaAppBarTitle(title: 'Ler acesso por QR Code'),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
          Center(
            child: IgnorePointer(
              child: Container(
                width: 268,
                height: 268,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white, width: 4),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 28,
            child: Card(
              color: const Color(0xE6082147),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error ??
                      'Aponte a câmera para o QR Code fornecido pela coordenação. '
                          'Servidor e credencial serão preenchidos automaticamente.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
