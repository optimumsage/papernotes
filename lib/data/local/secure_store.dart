import 'dart:convert';
import 'dart:io';

import 'package:encrypt/encrypt.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// In-app encrypted key/value store for secrets (Google client secret and
/// refresh token). Replaces the OS keychain so the app needs no special
/// entitlements and behaves identically on every platform.
///
/// Values are encrypted with **AES-256-GCM**. A random 256-bit key is created
/// on first run and kept in a file in the app-support directory (locked to the
/// current user with `chmod 600` where the OS allows it), separate from the
/// encrypted blob. This is encryption at rest: it protects the secret from
/// casual inspection and from cloud/file backups of the app data, but — like
/// any keyless-passphrase scheme — a determined local attacker with filesystem
/// access could recover the key. That is the accepted trade-off for dropping
/// the OS keychain dependency.
class SecureStore {
  Key? _key;
  Map<String, String>? _cache;

  static const _keyFileName = 'papernotes_secret.key';
  static const _dataFileName = 'papernotes_secret.enc';

  Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final dir = await getApplicationSupportDirectory();
    _key = await _loadOrCreateKey(p.join(dir.path, _keyFileName));
    _cache = await _loadData(File(p.join(dir.path, _dataFileName)));
  }

  Future<String?> read(String key) async {
    await _ensureLoaded();
    return _cache![key];
  }

  Future<void> write(String key, String value) async {
    await _ensureLoaded();
    _cache![key] = value;
    await _persist();
  }

  Future<void> delete(String key) async {
    await _ensureLoaded();
    _cache!.remove(key);
    await _persist();
  }

  // ---- internals ----

  Future<Key> _loadOrCreateKey(String path) async {
    final file = File(path);
    if (await file.exists()) {
      return Key.fromBase64((await file.readAsString()).trim());
    }
    final key = Key.fromSecureRandom(32);
    await file.writeAsString(key.base64, flush: true);
    await _restrictPermissions(path);
    return key;
  }

  Future<Map<String, String>> _loadData(File file) async {
    if (!await file.exists()) return {};
    try {
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) return {};
      final parts = raw.split(':');
      final iv = IV.fromBase64(parts[0]);
      final encrypted = Encrypted.fromBase64(parts[1]);
      final encrypter = Encrypter(AES(_key!, mode: AESMode.gcm));
      final json = encrypter.decrypt(encrypted, iv: iv);
      return (jsonDecode(json) as Map).cast<String, String>();
    } catch (_) {
      // Corrupt or key-mismatched blob — start clean rather than crash.
      return {};
    }
  }

  Future<void> _persist() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, _dataFileName));
    final iv = IV.fromSecureRandom(12); // 96-bit nonce for GCM
    final encrypter = Encrypter(AES(_key!, mode: AESMode.gcm));
    final encrypted = encrypter.encrypt(jsonEncode(_cache), iv: iv);
    await file.writeAsString('${iv.base64}:${encrypted.base64}', flush: true);
    await _restrictPermissions(file.path);
  }

  /// Best-effort: lock the file to the current user on POSIX systems.
  Future<void> _restrictPermissions(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {
      // Non-fatal — encryption still applies regardless of file mode.
    }
  }
}
