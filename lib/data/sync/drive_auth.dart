import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../settings_service.dart';

/// Result of a token exchange/refresh.
class _TokenSet {
  final String accessToken;
  final DateTime expiry;
  final String? refreshToken;
  _TokenSet(this.accessToken, this.expiry, this.refreshToken);
}

class DriveAuthException implements Exception {
  final String message;
  DriveAuthException(this.message);
  @override
  String toString() => 'DriveAuthException: $message';
}

/// Handles Google OAuth 2.0 (Authorization Code + PKCE) using the user's own
/// pasted client id/secret. A loopback redirect (`http://127.0.0.1:<port>`) is
/// used on every desktop platform and on Android — the OS browser posts the
/// auth code back to a short-lived local server. The long-lived refresh token
/// is stored securely; access tokens are minted on demand and cached in memory.
class DriveAuth {
  DriveAuth(this._settings);

  final SettingsService _settings;

  String? _accessToken;
  DateTime? _accessExpiry;

  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  bool get _accessValid =>
      _accessToken != null &&
      _accessExpiry != null &&
      DateTime.now().isBefore(_accessExpiry!.subtract(const Duration(seconds: 30)));

  /// Interactive sign-in. Opens the consent screen, captures the code via a
  /// loopback server, exchanges it, and persists the refresh token.
  /// Returns true on success.
  Future<bool> signIn() async {
    final clientId = await _settings.readClientId();
    final clientSecret = await _settings.readClientSecret();
    if (clientId == null || clientId.isEmpty ||
        clientSecret == null || clientSecret.isEmpty) {
      throw DriveAuthException(
          'Add your Google client ID and secret in Settings first.');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = 'http://127.0.0.1:${server.port}';
      final verifier = _randomString(64);
      final challenge = _codeChallenge(verifier);
      final state = _randomString(24);

      final authUrl = Uri.parse(_authEndpoint).replace(queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': AppConfig.driveScope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent',
      });

      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw DriveAuthException('Could not open the browser for sign-in.');
      }

      final code = await _awaitRedirect(server, state);
      final tokens = await _exchangeCode(
        clientId: clientId,
        clientSecret: clientSecret,
        code: code,
        redirectUri: redirectUri,
        verifier: verifier,
      );

      if (tokens.refreshToken == null) {
        throw DriveAuthException(
            'Google did not return a refresh token. Revoke prior access and retry.');
      }
      await _settings.setRefreshToken(tokens.refreshToken);
      _accessToken = tokens.accessToken;
      _accessExpiry = tokens.expiry;
      return true;
    } finally {
      await server.close(force: true);
    }
  }

  Future<void> signOut() async {
    _accessToken = null;
    _accessExpiry = null;
    await _settings.setRefreshToken(null);
  }

  Future<bool> get isSignedIn async {
    final t = await _settings.readRefreshToken();
    return t != null && t.isNotEmpty;
  }

  /// Returns a valid access token, refreshing via the stored refresh token if
  /// the cached one is missing or near expiry.
  Future<String> accessToken() async {
    if (_accessValid) return _accessToken!;
    final refresh = await _settings.readRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      throw DriveAuthException('Not signed in to Google Drive.');
    }
    final clientId = await _settings.readClientId();
    final clientSecret = await _settings.readClientSecret();
    if (clientId == null || clientSecret == null) {
      throw DriveAuthException('Missing client credentials.');
    }

    final tokens = await _refresh(
      clientId: clientId,
      clientSecret: clientSecret,
      refreshToken: refresh,
    );
    _accessToken = tokens.accessToken;
    _accessExpiry = tokens.expiry;
    return _accessToken!;
  }

  // ---- internals ----

  Future<String> _awaitRedirect(HttpServer server, String state) async {
    final completer = Completer<String>();
    final sub = server.listen((HttpRequest request) async {
      final params = request.uri.queryParameters;
      final ok = params['error'] == null &&
          params['code'] != null &&
          params['state'] == state;

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_resultPage(ok));
      await request.response.close();

      if (completer.isCompleted) return;
      if (ok) {
        completer.complete(params['code']!);
      } else {
        completer.completeError(
            DriveAuthException(params['error'] ?? 'Authorization failed.'));
      }
    });

    try {
      return await completer.future
          .timeout(const Duration(minutes: 5), onTimeout: () {
        throw DriveAuthException('Sign-in timed out.');
      });
    } finally {
      await sub.cancel();
    }
  }

  Future<_TokenSet> _exchangeCode({
    required String clientId,
    required String clientSecret,
    required String code,
    required String redirectUri,
    required String verifier,
  }) {
    return _postToken({
      'client_id': clientId,
      'client_secret': clientSecret,
      'code': code,
      'code_verifier': verifier,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
    });
  }

  Future<_TokenSet> _refresh({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) {
    return _postToken({
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
  }

  Future<_TokenSet> _postToken(Map<String, String> body) async {
    final res = await http.post(Uri.parse(_tokenEndpoint), body: body);
    if (res.statusCode != 200) {
      // Surface Google's error/description so credential problems are clear.
      String detail = '';
      try {
        final err = jsonDecode(res.body) as Map<String, dynamic>;
        final code = err['error'];
        final desc = err['error_description'];
        if (code == 'invalid_client') {
          detail = ' — the client secret is wrong or doesn\'t match the '
              'client ID. Re-enter your Client secret in Settings and retry.';
        } else if (code != null) {
          detail = ' — $code${desc != null ? ': $desc' : ''}';
        }
      } catch (_) {
        // Body wasn't JSON; fall back to the bare status code.
      }
      throw DriveAuthException('Token request failed (${res.statusCode})$detail');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return _TokenSet(
      json['access_token'] as String,
      DateTime.now().add(Duration(seconds: expiresIn)),
      json['refresh_token'] as String?,
    );
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)])
        .join();
  }

  static String _codeChallenge(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  static String _resultPage(bool ok) {
    final msg = ok
        ? 'Signed in to PaperNotes. You can close this tab.'
        : 'Sign-in failed. Return to PaperNotes and try again.';
    return '''
<!doctype html><html><head><meta charset="utf-8"><title>PaperNotes</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;display:flex;
height:100vh;margin:0;align-items:center;justify-content:center;background:#f7f7fb;color:#1e1e22}
.card{padding:32px 40px;border-radius:16px;background:#fff;box-shadow:0 8px 30px rgba(0,0,0,.08);font-size:18px}</style>
</head><body><div class="card">$msg</div></body></html>''';
  }
}
