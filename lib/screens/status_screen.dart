import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/auth_service.dart';
import '../services/background_sync_service.dart';
import 'login_screen.dart';

const _nativeChannel = MethodChannel('com.clipcascade/clipboard');

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> with WidgetsBindingObserver {
  final _auth = AuthService();
  final _sync = BackgroundSyncService();

  bool _isSyncing = false;
  Timer? _clipboardPollTimer;
  String? _lastLocalClip;
  String _status = 'disconnected';
  String _lastRemoteClip = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _sync.onStatusChanged = (status) {
      print('[StatusScreen] Status changed: $status');
      if (mounted) setState(() => _status = status);
    };

    _sync.onClipboardUpdate = (content) {
      print('[StatusScreen] Clipboard update received (${content.length} chars)');
      if (mounted) {
        setState(() => _lastRemoteClip = content);
        _setClipboard(content);
      }
    };

    _checkExistingService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardPollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isSyncing) {
      _startClipboardPolling();
    } else if (state == AppLifecycleState.paused) {
      _clipboardPollTimer?.cancel();
    }
  }

  Future<void> _checkExistingService() async {
    final running = await _sync.isRunning();
    if (running) {
      // Re-register event listeners for the already-running service
      _sync.registerListeners();
      setState(() => _isSyncing = true);
      _startClipboardPolling();
    }
  }

  Future<void> _startSync() async {
    if (!await _requestPermissions()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notification permission is required for sync'),
          ),
        );
      }
      return;
    }

    // Check overlay permission
    try {
      final hasOverlay = await _nativeChannel.invokeMethod('hasOverlayPermission') as bool;
      if (!hasOverlay && mounted) {
        final shouldOpen = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Overlay Permission'),
            content: const Text(
              'ClipCascade needs "Display over other apps" permission to read the clipboard in the background.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open Settings')),
            ],
          ),
        );
        if (shouldOpen == true) {
          await _nativeChannel.invokeMethod('requestOverlayPermission');
          return;
        }
      }
    } catch (_) {}

    // Check battery optimization
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      try {
        await _nativeChannel.invokeMethod('requestBatteryExemption');
      } catch (_) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    }

    final cookieHeader = await _auth.getCookieHeader();
    if (cookieHeader.isEmpty || _auth.serverUrl == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not authenticated. Please login again.')),
        );
        _navigateToLogin();
      }
      return;
    }

    final started = await _sync.start(_auth.serverUrl!, cookieHeader,
        encryptionKey: _auth.encryptionKey);
    if (started) {
      setState(() => _isSyncing = true);
      _startClipboardPolling();
    }
  }

  Future<void> _stopSync() async {
    await _sync.stop();
    _clipboardPollTimer?.cancel();
    setState(() {
      _isSyncing = false;
      _status = 'disconnected';
    });
  }

  Future<bool> _requestPermissions() async {
    if (await Permission.notification.isDenied) {
      final result = await Permission.notification.request();
      if (!result.isGranted) return false;
    }
    return true;
  }

  void _startClipboardPolling() {
    _clipboardPollTimer?.cancel();
    _clipboardPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollClipboard(),
    );
  }

  Future<void> _pollClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final currentClip = data?.text;
      if (currentClip != null &&
          currentClip.isNotEmpty &&
          currentClip != _lastLocalClip &&
          currentClip != _lastRemoteClip) {
        _lastLocalClip = currentClip;
        _sync.sendClipboard(currentClip);
      }
    } catch (_) {}
  }

  Future<void> _setClipboard(String content) async {
    try {
      print('[StatusScreen] Setting clipboard (${content.length} chars)');
      await Clipboard.setData(ClipboardData(text: content));
      _lastLocalClip = content;
      print('[StatusScreen] Clipboard set successfully');
    } catch (e) {
      print('[StatusScreen] Failed to set clipboard: $e');
    }
  }

  Future<void> _logout() async {
    await _stopSync();
    await _auth.logout();
    if (mounted) _navigateToLogin();
  }

  void _navigateToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Color _statusColor() {
    switch (_status) {
      case 'connected':
        return Colors.green;
      case 'connecting':
        return Colors.orange;
      case 'error':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon() {
    switch (_status) {
      case 'connected':
        return Icons.cloud_done_rounded;
      case 'connecting':
        return Icons.cloud_sync_rounded;
      case 'error':
        return Icons.cloud_off_rounded;
      default:
        return Icons.cloud_queue_rounded;
    }
  }

  String _statusText() {
    switch (_status) {
      case 'connected':
        return 'Connected';
      case 'connecting':
        return 'Connecting…';
      case 'error':
        return 'Connection error';
      case 'stopped':
        return 'Stopped';
      default:
        return 'Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipCascade'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') _logout();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Logout'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // User info
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.person_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _auth.username ?? '',
                            style: theme.textTheme.titleMedium,
                          ),
                          Text(
                            _auth.serverUrl ?? '',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Connection status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Icon(
                      _statusIcon(),
                      size: 48,
                      color: _statusColor(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusText(),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _statusColor(),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_status == 'error' || _status == 'disconnected')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Will retry automatically',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Start / Stop button
            SizedBox(
              height: 48,
              child: _isSyncing
                  ? FilledButton.icon(
                      onPressed: _stopSync,
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Stop Sync'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: _startSync,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Start Sync'),
                    ),
            ),
            const Spacer(),

            // Last synced content preview
            if (_lastRemoteClip.isNotEmpty) ...[
              const Divider(),
              Text(
                'Last received',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _lastRemoteClip.length > 200
                      ? '${_lastRemoteClip.substring(0, 200)}…'
                      : _lastRemoteClip,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
