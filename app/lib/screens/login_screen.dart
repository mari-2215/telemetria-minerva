import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../qr_login.dart';
import '../widgets/minerva_logo.dart';
import 'qr_login_scanner.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  final Future<void> Function(String server, String token) onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(
    text: kIsWeb ? '${Uri.base.origin}/api' : 'http://localhost:8080',
  );
  final _token = TextEditingController();

  bool _busy = false;
  bool _showToken = false;
  String? _error;

  bool get _scannerSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_server.text.trim().isEmpty || _token.text.trim().isEmpty) {
      setState(() => _error = 'Informe o servidor e a credencial de acesso.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onLogin(
        _server.text.trim().replaceAll(RegExp(r'/$'), ''),
        _token.text.trim(),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanQr() async {
    final login = await Navigator.of(context).push<MinervaLoginQr>(
      MaterialPageRoute(builder: (_) => const QrLoginScannerScreen()),
    );
    if (login == null || !mounted) return;

    _server.text = login.server;
    _token.text = login.token;
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(26, 28, 26, 26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: MinervaLogo()),
                      const SizedBox(height: 18),
                      Text(
                        'Telemetria Minerva',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Monitoramento e piloto automático naval',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 26),
                      if (_scannerSupported) ...[
                        FilledButton.icon(
                          onPressed: _busy ? null : _scanQr,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Entrar com QR Code'),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Row(
                            children: [
                              Expanded(child: Divider()),
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text('OU DIGITE MANUALMENTE'),
                              ),
                              Expanded(child: Divider()),
                            ],
                          ),
                        ),
                      ],
                      TextField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Servidor',
                          prefixIcon: Icon(Icons.dns_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _token,
                        obscureText: !_showToken,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'Credencial de acesso',
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _showToken = !_showToken),
                            icon: Icon(
                              _showToken
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: const Icon(Icons.login_rounded),
                        label: Text(
                          _busy ? 'Conectando...' : 'Entrar manualmente',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Não compartilhe fotografias do QR Code. '
                        'Cada código concede acesso ao perfil indicado.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
