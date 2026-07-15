import 'package:flutter/material.dart';

import '../widgets/minerva_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});
  final Future<void> Function(String server, String token) onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(text: 'http://localhost:8080');
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.onLogin(_server.text.trim(), _token.text.trim());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: MinervaLogo()),
                    const SizedBox(height: 16),
                    Text('Telemetria e Piloto Automático', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    TextField(controller: _server, decoration: const InputDecoration(labelText: 'Servidor', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: _token, obscureText: true, decoration: const InputDecoration(labelText: 'Token de acesso', border: OutlineInputBorder())),
                    if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 20),
                    FilledButton.icon(onPressed: _busy ? null : _submit, icon: const Icon(Icons.login), label: Text(_busy ? 'Conectando...' : 'Entrar')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
