import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/auth_service.dart';
import 'services/background_sync_service.dart';
import 'screens/login_screen.dart';
import 'screens/status_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background service before runApp
  await BackgroundSyncService().initialize();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent),
  );

  runApp(const ClipCascadeApp());
}

class ClipCascadeApp extends StatefulWidget {
  const ClipCascadeApp({super.key});

  @override
  State<ClipCascadeApp> createState() => _ClipCascadeAppState();
}

class _ClipCascadeAppState extends State<ClipCascadeApp> {
  final _auth = AuthService();
  bool _checkingAuth = true;

  @override
  void initState() {
    super.initState();
    _tryAutoLogin();
  }

  Future<void> _tryAutoLogin() async {
    await _auth.tryAutoLogin();
    if (mounted) setState(() => _checkingAuth = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipCascade',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: _checkingAuth
          ? const _SplashScreen()
          : _auth.isLoggedIn
              ? const StatusScreen()
              : const LoginScreen(),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.content_paste_rounded, size: 64,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Deriving encryption key...',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
