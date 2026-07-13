import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

/// The single crypto authority for PaperNote's optional end-to-end encryption.
///
/// When encryption is enabled the app generates one random 256-bit **master
/// key**, shown to the user once. The same key is used at two boundaries:
///   * **at rest** — the content columns of the local database are encrypted
///     via [maybeEncrypt]/[maybeDecrypt] in the Drift row mappers;
///   * **in transit** — each note/folder payload is wrapped with
///     [wrapPayload]/[unwrapPayload] and attachment bytes with
///     [encryptBytes]/[maybeDecryptBytes] before/after Google Drive sync.
///
/// The service holds the loaded key in memory ([isUnlocked]); it is null when
/// encryption is disabled or the device hasn't been unlocked yet. All the
/// string/byte helpers are **passthrough** when the input isn't in encrypted
/// form, so a half-migrated (mixed plaintext + ciphertext) store decrypts
/// safely and re-encryption is idempotent.
///
/// AES-256-GCM (authenticated) via the `encrypt` package, matching the format
/// [SecureStore] already uses elsewhere in the app.
class EncryptionService {
  Key? _key;

  /// Marks an encrypted string field: `<SOH>enc1:<ivBase64>:<ctBase64>`. The
  /// leading U+0001 (start-of-heading control char) can't occur in a note's
  /// title/body (Delta JSON) or a folder name, so plaintext never collides with
  /// the marker even when encryption is disabled.
  static const sentinel = '\u0001enc1:';
  static const _sentinel = sentinel;

  /// Magic prefix on an encrypted binary blob (attachments): "PNE1".
  static const List<int> _byteMagic = [0x50, 0x4E, 0x45, 0x31];

  bool get isUnlocked => _key != null;

  /// Load the master key into memory so the encrypt/decrypt helpers work.
  void unlock(String base64Key) => _key = keyFromString(base64Key);

  /// Drop the in-memory key (e.g. on disable). Data already written stays as
  /// it was until re-migrated.
  void lock() => _key = null;

  // ---- key helpers ----

  /// A fresh random 256-bit master key, base64-encoded (what the user saves).
  static String generateMasterKey() => Key.fromSecureRandom(32).base64;

  /// Parse + validate a base64 master key (must decode to exactly 32 bytes).
  static Key keyFromString(String base64Key) {
    final key = Key.fromBase64(base64Key.trim());
    if (key.bytes.length != 32) {
      throw const FormatException('Master key must be 256-bit');
    }
    return key;
  }

  /// True when [base64Key] is a syntactically valid master key.
  static bool isValidKey(String base64Key) {
    try {
      keyFromString(base64Key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A short, non-secret fingerprint of a key, stored alongside the encrypted
  /// data so other devices can tell when the master key has *changed* (and
  /// re-prompt) without exposing the key itself.
  static String fingerprint(String base64Key) {
    final digest = sha256.convert(keyFromString(base64Key).bytes);
    return base64Url.encode(digest.bytes).substring(0, 12);
  }

  // ---- string fields (DB columns) ----

  /// Encrypt a nullable field for storage. Null / locked / already-encrypted →
  /// returned unchanged (so a disabled or not-yet-unlocked store keeps writing
  /// plaintext, and re-encryption is idempotent).
  String? maybeEncrypt(String? value) {
    if (value == null || !isUnlocked || value.startsWith(_sentinel)) {
      return value;
    }
    return encryptString(value);
  }

  /// Decrypt a nullable stored field. Null → null; a value without the
  /// [_sentinel] (legacy plaintext) → returned unchanged. A sentinel-tagged
  /// value that can't be decrypted (locked, or wrong key) → **null**, so
  /// callers that `jsonDecode` the result (checklist items / attachments) get
  /// an empty list instead of a `FormatException` on ciphertext.
  String? maybeDecrypt(String? value) {
    if (value == null) return null;
    if (!value.startsWith(_sentinel)) return value; // plaintext passthrough
    final key = _key;
    if (key == null) return null; // locked — degrade to empty, never crash
    return _tryDecrypt(key, value); // null on wrong-key/corrupt
  }

  String encryptString(String plain) {
    final iv = IV.fromSecureRandom(12); // 96-bit GCM nonce
    final enc = Encrypter(AES(_key!, mode: AESMode.gcm)).encrypt(plain, iv: iv);
    return '$_sentinel${iv.base64}:${enc.base64}';
  }

  String decryptString(String stored) {
    if (!stored.startsWith(_sentinel)) return stored; // plaintext passthrough
    final key = _key;
    if (key == null) return stored; // locked — can't decrypt, don't crash
    final plain = _tryDecrypt(key, stored);
    return plain ?? stored;
  }

  /// Attempt to decrypt [stored] with a *candidate* key (used to validate a
  /// typed-in master key against the Drive canary). Returns null on any
  /// failure or key mismatch (GCM auth-tag rejection).
  static String? tryDecryptWith(String base64Key, String stored) {
    try {
      return _tryDecrypt(keyFromString(base64Key), stored);
    } catch (_) {
      return null;
    }
  }

  static String? _tryDecrypt(Key key, String stored) {
    if (!stored.startsWith(_sentinel)) return null;
    try {
      final rest = stored.substring(_sentinel.length);
      final sep = rest.indexOf(':');
      final iv = IV.fromBase64(rest.substring(0, sep));
      final enc = Encrypted.fromBase64(rest.substring(sep + 1));
      return Encrypter(AES(key, mode: AESMode.gcm)).decrypt(enc, iv: iv);
    } catch (_) {
      return null;
    }
  }

  // ---- Drive payload envelope (notes / folders) ----

  /// Wrap a cleartext note/folder JSON string in a self-describing encrypted
  /// envelope for upload. Passthrough when locked.
  String wrapPayload(String json) {
    if (!isUnlocked) return json;
    return jsonEncode({'pnenc': 1, 'd': encryptString(json)});
  }

  /// Reverse of [wrapPayload]: a downloaded map is either an encrypted envelope
  /// (`{"pnenc":1,"d":...}`) or a plain note/folder map (un-migrated remote
  /// file). Returns the decrypted inner map, or the input map unchanged.
  Map<String, dynamic> unwrapPayload(Map<String, dynamic> payload) {
    if (payload['pnenc'] == 1 && payload['d'] is String) {
      final inner = decryptString(payload['d'] as String);
      return (jsonDecode(inner) as Map).cast<String, dynamic>();
    }
    return payload;
  }

  // ---- attachment binaries ----

  /// Encrypt raw attachment bytes: `magic ‖ nonce(12) ‖ ciphertext+tag`.
  List<int> encryptBytes(List<int> bytes) {
    final iv = IV.fromSecureRandom(12);
    final enc = Encrypter(AES(_key!, mode: AESMode.gcm)).encryptBytes(bytes, iv: iv);
    return <int>[..._byteMagic, ...iv.bytes, ...enc.bytes];
  }

  /// Decrypt attachment bytes if they carry the [_byteMagic] header; otherwise
  /// (legacy plaintext binary, or locked, or wrong key) return them unchanged
  /// rather than throwing, so a bad/mismatched binary never crashes sync.
  List<int> maybeDecryptBytes(List<int> bytes) {
    if (!_hasMagic(bytes) || _key == null) return bytes;
    try {
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      final iv = IV(Uint8List.fromList(
          data.sublist(_byteMagic.length, _byteMagic.length + 12)));
      final ct =
          Encrypted(Uint8List.fromList(data.sublist(_byteMagic.length + 12)));
      return Encrypter(AES(_key!, mode: AESMode.gcm)).decryptBytes(ct, iv: iv);
    } catch (_) {
      return bytes; // wrong key / corrupt — fail soft
    }
  }

  static bool _hasMagic(List<int> bytes) {
    if (bytes.length < _byteMagic.length) return false;
    for (var i = 0; i < _byteMagic.length; i++) {
      if (bytes[i] != _byteMagic[i]) return false;
    }
    return true;
  }
}
