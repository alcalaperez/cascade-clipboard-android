import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';

import 'crypto_service.dart';

/// Manages the foreground service that maintains the STOMP WebSocket connection
/// for clipboard synchronization.
class BackgroundSyncService {
  static final BackgroundSyncService _instance = BackgroundSyncService._();
  factory BackgroundSyncService() => _instance;
  BackgroundSyncService._();

  final _service = FlutterBackgroundService();
  StreamSubscription? _statusSub;
  StreamSubscription? _clipboardSub;

  String _status = 'disconnected';
  String _lastRemoteClip = '';

  String get status => _status;
  String get lastRemoteClip => _lastRemoteClip;

  /// Callback when connection status changes.
  void Function(String status)? onStatusChanged;

  /// Callback when a remote clipboard update is received.
  void Function(String content)? onClipboardUpdate;

  /// Initialize the background service (call before runApp).
  Future<void> initialize() async {
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: 'clipcascade_sync',
        initialNotificationTitle: 'ClipCascade',
        initialNotificationContent: 'Clipboard sync active',
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
  }

  /// Register event listeners on an already-running service.
  /// Called when the app restarts while the background service is still active.
  void registerListeners() {
    _statusSub?.cancel();
    _clipboardSub?.cancel();

    _statusSub = _service.on('statusUpdate').listen((event) {
      if (event != null) {
        _status = event['status'] as String? ?? 'unknown';
        print('[SyncService] statusUpdate: $_status');
        onStatusChanged?.call(_status);
      }
    });

    _clipboardSub = _service.on('clipboardUpdate').listen((event) {
      if (event != null) {
        _lastRemoteClip = event['content'] as String? ?? '';
        print('[SyncService] clipboardUpdate: ${_lastRemoteClip.length} chars');
        onClipboardUpdate?.call(_lastRemoteClip);
      }
    });
  }

  /// Start the sync service.
  Future<bool> start(String serverUrl, String cookieHeader, {List<int>? encryptionKey}) async {
    final alreadyRunning = await _service.isRunning();
    final started = alreadyRunning || await _service.startService();
    if (!started) return false;

    // Small delay to ensure service isolate is ready
    await Future.delayed(const Duration(milliseconds: 300));

    // Always register fresh listeners
    registerListeners();

    // Always invoke connect — this re-establishes the STOMP session
    // whether the service is freshly started or already running
    _service.invoke('connect', {
      'serverUrl': serverUrl,
      'cookieHeader': cookieHeader,
      'encryptionKey': encryptionKey,
    });

    return true;
  }

  /// Stop the sync service.
  Future<void> stop() async {
    _service.invoke('stop');
    _statusSub?.cancel();
    _clipboardSub?.cancel();
    _status = 'disconnected';
    onStatusChanged?.call(_status);
  }

  /// Send local clipboard content to the server.
  void sendClipboard(String content) {
    _service.invoke('sendClipboard', {'content': content});
  }

  /// Check if the service is currently running.
  Future<bool> isRunning() async {
    return await _service.isRunning();
  }
}

// ---------------------------------------------------------------------------
// Background service entry point — runs in a separate Dart isolate.
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  StompClient? stompClient;
  String? lastSentContent;
  String? lastReceivedContent;
  Timer? reconnectTimer;
  int reconnectAttempts = 0;
  String? currentServerUrl;
  String? currentCookieHeader;
  Uint8List? encKey;
  const maxReconnectDelay = 60;

  // Use late-binding to allow mutual recursion between connect/scheduleReconnect
  late void Function() doConnect;
  late void Function() doScheduleReconnect;

  doScheduleReconnect = () {
    reconnectTimer?.cancel();
    reconnectAttempts++;
    final delay = min(
      maxReconnectDelay,
      pow(2, reconnectAttempts - 1).toInt(),
    );
    reconnectTimer = Timer(Duration(seconds: delay), doConnect);
  };

  doConnect = () {
    if (currentServerUrl == null) return;

    stompClient?.deactivate();
    reconnectTimer?.cancel();

    service.invoke('statusUpdate', {'status': 'connecting'});

    // Convert http(s) to ws(s) for raw WebSocket
    final wsUrl = currentServerUrl!
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://');

    print('[ClipCascade] Connecting to $wsUrl/clipsocket');

    stompClient = StompClient(
      config: StompConfig(
        url: '$wsUrl/clipsocket',
        webSocketConnectHeaders: {
          'Cookie': currentCookieHeader ?? '',
        },
        onConnect: (StompFrame frame) {
          print('[ClipCascade] STOMP connected');
          reconnectAttempts = 0;
          service.invoke('statusUpdate', {'status': 'connected'});

          stompClient!.subscribe(
            destination: '/user/queue/cliptext',
            callback: (StompFrame frame) {
              print('[ClipCascade] SUBSCRIBE callback fired! body=${frame.body?.substring(0, frame.body!.length > 50 ? 50 : frame.body!.length)}');
              final body = frame.body;
              if (body != null) {
                try {
                  final msg = jsonDecode(body) as Map<String, dynamic>;
                  var payload = msg['payload'] as String?;
                  if (payload != null) {
                    // Decrypt if encryption is enabled and payload looks encrypted
                    if (encKey != null && payload.startsWith('{')) {
                      try {
                        final enc = jsonDecode(payload) as Map<String, dynamic>;
                        if (enc.containsKey('nonce') && enc.containsKey('ciphertext') && enc.containsKey('tag')) {
                          final nonce = base64Decode(enc['nonce'] as String);
                          final ciphertext = base64Decode(enc['ciphertext'] as String);
                          final tag = base64Decode(enc['tag'] as String);
                          final encrypted = Uint8List.fromList([...nonce, ...ciphertext, ...tag]);
                          payload = utf8.decode(aesGcmDecrypt(encrypted, encKey!));
                        }
                      } catch (_) {
                        // Not encrypted or decryption failed, use as-is
                      }
                    }
                    if (payload != null && payload != lastSentContent) {
                      lastSentContent = payload;
                      lastReceivedContent = payload;
                      print('[ClipCascade] Invoking clipboardUpdate with ${payload!.length} chars');
                      service.invoke('clipboardUpdate', {'content': payload});
                    }
                  }
                } catch (e) {
                  print('[ClipCascade] Failed to parse message: $e');
                }
              }
            },
          );
        },
        onDisconnect: (StompFrame frame) {
          print('[ClipCascade] STOMP disconnected');
          service.invoke('statusUpdate', {'status': 'disconnected'});
          doScheduleReconnect();
        },
        onWebSocketError: (dynamic error) {
          print('[ClipCascade] WebSocket error: $error');
          service.invoke('statusUpdate', {'status': 'error'});
          doScheduleReconnect();
        },
        onStompError: (StompFrame frame) {
          print('[ClipCascade] STOMP error: ${frame.body}');
          service.invoke('statusUpdate', {'status': 'error'});
          doScheduleReconnect();
        },
        onUnhandledFrame: (StompFrame frame) {
          print('[ClipCascade] Unhandled frame: command=${frame.command} headers=${frame.headers} body=${frame.body}');
        },
        onUnhandledMessage: (StompFrame frame) {
          print('[ClipCascade] Unhandled message: headers=${frame.headers} body=${frame.body}');
        },
        onDebugMessage: (dynamic log) {
          print('[ClipCascade STOMP] $log');
        },
        heartbeatIncoming: const Duration(seconds: 10),
        heartbeatOutgoing: const Duration(seconds: 10),
        reconnectDelay: Duration.zero, // we manage reconnect ourselves
      ),
    );

    stompClient!.activate();
  };

  service.on('connect').listen((event) {
    if (event != null) {
      currentServerUrl = event['serverUrl'] as String?;
      currentCookieHeader = event['cookieHeader'] as String?;
      final keyList = event['encryptionKey'];
      encKey = keyList != null ? Uint8List.fromList(List<int>.from(keyList)) : null;
      reconnectAttempts = 0;
      lastSentContent = null;
      doConnect();
    }
  });

  service.on('stop').listen((event) {
    stompClient?.deactivate();
    stompClient = null;
    reconnectTimer?.cancel();
    lastSentContent = null;
    service.invoke('statusUpdate', {'status': 'stopped'});
  });

  service.on('sendClipboard').listen((event) {
    if (event != null) {
      final content = event['content'] as String?;
      if (stompClient != null && content != null && content != lastSentContent) {
        lastSentContent = content;
        try {
          String payload = content;
          if (encKey != null) {
            final encrypted = aesGcmEncrypt(Uint8List.fromList(utf8.encode(content)), encKey!);
            final nonce = base64Encode(encrypted.sublist(0, 16));
            final ciphertextAndTag = encrypted.sublist(16);
            final tag = base64Encode(ciphertextAndTag.sublist(ciphertextAndTag.length - 16));
            final ciphertext = base64Encode(ciphertextAndTag.sublist(0, ciphertextAndTag.length - 16));
            payload = jsonEncode({'nonce': nonce, 'ciphertext': ciphertext, 'tag': tag});
          }
          final msg = jsonEncode({'payload': payload, 'type': 'text'});
          stompClient!.send(destination: '/app/cliptext', body: msg);
        } catch (_) {}
      }
    }
  });

  // Invoked when the service is stopped from the OS side.
  service.on('stopService').listen((event) {
    stompClient?.deactivate();
    reconnectTimer?.cancel();
  });

  // Poll shared preferences file directly for clipboard changes from native listener
  int lastClipTs = 0;
  Timer.periodic(const Duration(seconds: 1), (_) async {
    if (stompClient == null) return;
    try {
      final dir = '/data/data/com.clipcascade.clipcascade_client/shared_prefs';
      final file = File('$dir/FlutterSharedPreferences.xml');
      if (!file.existsSync()) return;
      final xml = await file.readAsString();

      // Parse timestamp
      final tsMatch = RegExp(r'name="flutter\.clip_ts"[^>]*value="(\d+)"').firstMatch(xml);
      final ts = tsMatch != null ? int.tryParse(tsMatch.group(1)!) ?? 0 : 0;
      if (ts <= lastClipTs) return;

      // Parse content and decode XML entities
      final contentMatch = RegExp(r'name="flutter\.clip_content"[^>]*>([^<]*)<').firstMatch(xml);
      var content = contentMatch?.group(1);
      if (content == null || content.isEmpty) return;
      content = content
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');

      lastClipTs = ts;
      // Skip if this is content we just received from server or already sent
      if (content == lastSentContent || content == lastReceivedContent) return;
      lastSentContent = content;
      String payload = content;
      if (encKey != null) {
        final encrypted = aesGcmEncrypt(Uint8List.fromList(utf8.encode(content)), encKey!);
        final nonce = base64Encode(encrypted.sublist(0, 16));
        final ciphertextAndTag = encrypted.sublist(16);
        final tag = base64Encode(ciphertextAndTag.sublist(ciphertextAndTag.length - 16));
        final ciphertext = base64Encode(ciphertextAndTag.sublist(0, ciphertextAndTag.length - 16));
        payload = jsonEncode({'nonce': nonce, 'ciphertext': ciphertext, 'tag': tag});
      }
      final msg = jsonEncode({'payload': payload, 'type': 'text'});
      stompClient?.send(destination: '/app/cliptext', body: msg);
      print('[ClipCascade] Sent native clipboard: ${content.length} chars');
    } catch (_) {}
  });
}
