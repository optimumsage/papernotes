import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/constants.dart';

/// Local device authentication for the app-lock gate.
///
/// Two independent credentials:
/// - a **PIN** (base credential, every platform) — hashed with a per-PIN salt
///   and stored via [SettingsService]/`SecureStore` (never in plaintext);
/// - optional **biometric** unlock (Android fingerprint / macOS Touch ID) via
///   `local_auth`, which always falls back to the PIN.
///
/// Windows has no biometric path here (PIN only), matching the product intent.
class AppLockService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Whether biometric unlock can be offered on this device: supported OS
  /// (Android or macOS — not Windows), hardware present, and at least one
  /// biometric enrolled. Never throws.
  Future<bool> isBiometricAvailable() async {
    if (!(Platform.isAndroid || Platform.isMacOS)) return false;
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// Human-readable name of the biometric method for UI copy.
  String biometricLabel() => Platform.isMacOS ? 'Touch ID' : 'fingerprint';

  /// Prompt for biometric authentication. Returns true only on success; any
  /// failure, cancellation, or platform error resolves to false so the caller
  /// falls back to the PIN.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }

  // ---- PIN hashing (pure) ----

  /// A fresh random salt (base64, 16 bytes) for a newly-set PIN.
  static String newSalt() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Encode(bytes);
  }

  /// Salted SHA-256 of [pin]. Returned as the `salt:hex` string that is stored.
  static String hashPin(String pin, String salt) {
    final digest = sha256.convert(utf8.encode('$salt:$pin'));
    return '$salt:${digest.toString()}';
  }

  /// Whether [pin] matches a previously [hashPin]'d `salt:hex` [stored] value.
  static bool verifyPin(String pin, String? stored) {
    if (stored == null) return false;
    final sep = stored.indexOf(':');
    if (sep <= 0) return false;
    final salt = stored.substring(0, sep);
    return hashPin(pin, salt) == stored;
  }

  // ---- Auto-lock decision (pure, testable) ----

  /// Whether the app should auto-lock after being backgrounded for [elapsed],
  /// given the configured [autoLockMinutes]. The restart sentinel never
  /// auto-locks (it only re-locks on a cold start).
  static bool shouldAutoLock({
    required int autoLockMinutes,
    required Duration elapsed,
  }) {
    if (autoLockMinutes == AppConfig.appLockRestartSentinel) return false;
    return elapsed >= Duration(minutes: autoLockMinutes);
  }
}
