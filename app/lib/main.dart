import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'screens/fleet_screen.dart';
import 'screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MinervaTelemetryApp());
}

class MinervaTelemetryApp extends StatefulWidget {
  const MinervaTelemetryApp({super.key});

  @override
  State<MinervaTelemetryApp> createState() => _MinervaTelemetryAppState();
}

class _MinervaTelemetryAppState extends State<MinervaTelemetryApp> {
  ApiClient? _client;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final preferences = await SharedPreferences.getInstance();
    final server = preferences.getString('server');
    final token = preferences.getString('token');
    if (server != null && token != null && mounted) {
      setState(() => _client = ApiClient(baseUrl: server, token: token));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _login(String server, String token) async {
    final candidate = ApiClient(baseUrl: server, token: token);
    await candidate.boats();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('server', server);
    await preferences.setString('token', token);
    _client?.close();
    if (mounted) setState(() => _client = candidate);
  }

  Future<void> _logout() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('server');
    await preferences.remove('token');
    _client?.close();
    if (mounted) setState(() => _client = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Telemetria Minerva',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0284C7), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF020B1C),
        cardTheme: const CardThemeData(color: Color(0xFF071A33), elevation: 2),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF03152C), surfaceTintColor: Colors.transparent),
        navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF03152C)),
        useMaterial3: true,
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _client == null
              ? LoginScreen(onLogin: _login)
              : FleetScreen(client: _client!, onLogout: _logout),
    );
  }
}
