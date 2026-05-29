import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html_parser;

import 'crypto_service.dart';

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._();
  factory AuthService() => _instance;
  AuthService._();

  final _storage = const FlutterSecureStorage();

  late Dio _dio;
  late CookieJar _cookieJar;

  String? _serverUrl;
  String? _username;
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _error;

  bool _encryptionEnabled = false;
  String _encryptionSalt = '';
  Uint8List? _encryptionKey;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get serverUrl => _serverUrl;
  String? get username => _username;
  String? get error => _error;
  bool get encryptionEnabled => _encryptionEnabled;
  Uint8List? get encryptionKey => _encryptionKey;

  void _initDio() {
    _cookieJar = CookieJar();
    _dio = Dio(BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
    ));
    _dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// Extract CSRF token from login page HTML.
  String? _extractCsrfToken(String html) {
    final document = html_parser.parse(html);
    // Try <input name="_csrf" value="...">
    final csrfInput = document.querySelector('input[name="_csrf"]');
    if (csrfInput != null) {
      return csrfInput.attributes['value'];
    }
    // Fallback: look for meta tag
    final metaTag = document.querySelector('meta[name="_csrf"]');
    return metaTag?.attributes['content'];
  }

  /// Perform login against the ClipCascade server.
  Future<bool> login(String serverUrl, String username, String password,
      {bool encrypt = false, String salt = ''}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _serverUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
      _username = username;
      _encryptionEnabled = encrypt;
      _encryptionSalt = salt;
      _initDio();

      // 1. Hash password with SHA3-512
      final hashedPassword = sha3_512Hash(password);

      // 2. GET /login — fetch CSRF token + session cookie
      final loginPage = await _dio.get<String>('$_serverUrl/login');
      final csrfToken = _extractCsrfToken(loginPage.data.toString());
      if (csrfToken == null) {
        _error = 'Could not extract CSRF token from login page';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // 3. POST /login with credentials
      final response = await _dio.post<dynamic>(
        '$_serverUrl/login',
        data:
            'username=${Uri.encodeComponent(username)}'
            '&password=$hashedPassword'
            '&_csrf=$csrfToken',
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          followRedirects: false,
        ),
      );

      // Check for failure indicators
      final body = response.data?.toString() ?? '';

      // 302 redirect back to /login means auth failure
      final location = response.headers['location'];
      if (location != null && location.any((l) => l.contains('/login'))) {
        _error = 'Invalid credentials';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // "bad credentials" in body means auth failure
      if (body.toLowerCase().contains('bad credentials')) {
        _error = 'Invalid credentials';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // 4. Verify we can fetch a fresh CSRF token (confirms session is valid)
      try {
        await _dio.get<dynamic>('$_serverUrl/csrf-token');
      } catch (_) {
        _error = 'Login succeeded but session verification failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      _isLoggedIn = true;

      // Derive encryption key if enabled
      if (_encryptionEnabled) {
        final keySalt = '$username$password$_encryptionSalt';
        _encryptionKey = deriveKey(password, keySalt);
      } else {
        _encryptionKey = null;
      }

      // Persist credentials for auto-login
      await _storage.write(key: 'server_url', value: _serverUrl);
      await _storage.write(key: 'username', value: _username);
      await _storage.write(key: 'password', value: password);
      await _storage.write(key: 'encrypt', value: _encryptionEnabled.toString());
      await _storage.write(key: 'salt', value: _encryptionSalt);

      _isLoading = false;
      notifyListeners();
      return true;
    } on DioException catch (e) {
      _error = _dioErrorToString(e);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Logout from the server and clear stored credentials.
  Future<void> logout() async {
    if (_isLoggedIn && _serverUrl != null) {
      try {
        final csrfResponse = await _dio.get<dynamic>(
          '$_serverUrl/csrf-token',
        );
        final csrfToken = csrfResponse.data['token'] as String?;
        if (csrfToken != null) {
          await _dio.post<dynamic>(
            '$_serverUrl/logout',
            data: '_csrf=$csrfToken',
            options: Options(
              contentType: 'application/x-www-form-urlencoded',
            ),
          );
        }
      } catch (_) {
        // Best-effort logout; ignore server errors.
      }
    }

    _isLoggedIn = false;
    _serverUrl = null;
    _username = null;
    _error = null;
    await _storage.deleteAll();
    notifyListeners();
  }

  /// Try auto-login from stored credentials.
  Future<bool> tryAutoLogin() async {
    final serverUrl = await _storage.read(key: 'server_url');
    final username = await _storage.read(key: 'username');
    final password = await _storage.read(key: 'password');
    final encrypt = (await _storage.read(key: 'encrypt')) == 'true';
    final salt = await _storage.read(key: 'salt') ?? '';

    if (serverUrl == null || username == null || password == null) {
      return false;
    }

    return login(serverUrl, username, password, encrypt: encrypt, salt: salt);
  }

  /// Get the current session cookie header for WebSocket handshake.
  Future<String> getCookieHeader() async {
    if (_serverUrl == null) return '';
    final uri = Uri.parse(_serverUrl!);
    final cookies = await _cookieJar.loadForRequest(uri);
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Get max clipboard size from server.
  Future<int?> getMaxSize() async {
    if (!_isLoggedIn || _serverUrl == null) return null;
    try {
      final response = await _dio.get<dynamic>('$_serverUrl/max-size');
      return response.data['maxsize'] as int?;
    } catch (_) {
      return null;
    }
  }

  String _dioErrorToString(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out';
      case DioExceptionType.connectionError:
        return 'Cannot connect to server. Check the URL and network.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return 'Server returned error $code';
      default:
        return e.message ?? 'Network error';
    }
  }
}
