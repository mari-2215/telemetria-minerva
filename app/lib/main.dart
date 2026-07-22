import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'models.dart';
import 'screens/fleet_screen.dart';
import 'screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Manrope'],
      await rootBundle.loadString('assets/fonts/OFL-Manrope.txt'),
    );
  });
  runApp(const MinervaTelemetryApp());
}

class MinervaTelemetryApp extends StatefulWidget {
  const MinervaTelemetryApp({super.key});

  @override
  State<MinervaTelemetryApp> createState() => _MinervaTelemetryAppState();
}

class _MinervaTelemetryAppState extends State<MinervaTelemetryApp> {
  ApiClient? _client;
  UserProfile? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final preferences = await SharedPreferences.getInstance();
    final storedServer = preferences.getString('server');
    final token = preferences.getString('token');
    final server = kIsWeb ? '${Uri.base.origin}/api' : storedServer;
    if (kIsWeb) {
      await preferences.setString('server', server!);
    }
    if (server != null && token != null) {
      final candidate = ApiClient(baseUrl: server, token: token);
      try {
        final profile = await candidate.me();
        await candidate.boats();
        if (mounted) {
          setState(() {
            _client = candidate;
            _profile = profile;
          });
        }
      } catch (_) {
        candidate.close();
        await preferences.remove('server');
        await preferences.remove('token');
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _login(String server, String token) async {
    final effectiveServer = kIsWeb ? '${Uri.base.origin}/api' : server;
    final candidate = ApiClient(baseUrl: effectiveServer, token: token);
    final profile = await candidate.me();
    await candidate.boats();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('server', effectiveServer);
    await preferences.setString('token', token);
    _client?.close();
    if (mounted) {
      setState(() {
        _client = candidate;
        _profile = profile;
      });
    }
  }

  Future<void> _logout() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('server');
    await preferences.remove('token');
    _client?.close();
    if (mounted) {
      setState(() {
        _client = null;
        _profile = null;
      });
    }
  }

  ThemeData _captainTheme() {
    const navy = Color(0xFF082B5C);
    const blue = Color(0xFF0B6CCB);
    final base = ThemeData(
      brightness: Brightness.light,
      colorScheme:
          ColorScheme.fromSeed(seedColor: blue, brightness: Brightness.light),
      scaffoldBackgroundColor: const Color(0xFFF4F7FB),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shadowColor: navy.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xFFE1EAF5)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: navy,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme:
          const NavigationBarThemeData(backgroundColor: Colors.white),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD8E4F1))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD8E4F1))),
      ),
      fontFamily: 'Manrope',
      useMaterial3: true,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800, color: navy, letterSpacing: -0.7),
        titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800, color: navy, letterSpacing: -0.45),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700, color: navy),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.4),
        labelLarge:
            base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      pageTransitionsTheme: _transitions,
    );
  }

  ThemeData _crewTheme() {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0284C7), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF020B1C),
      cardTheme: const CardThemeData(color: Color(0xFF071A33), elevation: 2),
      appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF03152C),
          surfaceTintColor: Colors.transparent),
      navigationBarTheme:
          const NavigationBarThemeData(backgroundColor: Color(0xFF03152C)),
      fontFamily: 'Manrope',
      useMaterial3: true,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        titleLarge: base.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.35),
        titleMedium:
            base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.35),
      ),
      pageTransitionsTheme: _transitions,
    );
  }

  static const _transitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: _MinervaPageTransitionsBuilder(),
      TargetPlatform.iOS: _MinervaPageTransitionsBuilder(),
      TargetPlatform.linux: _MinervaPageTransitionsBuilder(),
      TargetPlatform.macOS: _MinervaPageTransitionsBuilder(),
      TargetPlatform.windows: _MinervaPageTransitionsBuilder(),
    },
  );

  @override
  Widget build(BuildContext context) {
    final captain = _profile?.isCaptain ?? false;
    return MaterialApp(
      title: 'Telemetria Minerva',
      debugShowCheckedModeBanner: false,
      theme: captain ? _captainTheme() : _crewTheme(),
      themeAnimationDuration: const Duration(milliseconds: 700),
      themeAnimationCurve: Curves.easeInOutCubicEmphasized,
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _client == null || _profile == null
              ? LoginScreen(onLogin: _login)
              : FleetScreen(
                  client: _client!, profile: _profile!, onLogout: _logout),
    );
  }
}

class _MinervaPageTransitionsBuilder extends PageTransitionsBuilder {
  const _MinervaPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.965, end: 1).animate(curved),
        alignment: Alignment.center,
        child: SlideTransition(
          position:
              Tween<Offset>(begin: const Offset(0.035, 0.018), end: Offset.zero)
                  .animate(curved),
          child: child,
        ),
      ),
    );
  }
}
