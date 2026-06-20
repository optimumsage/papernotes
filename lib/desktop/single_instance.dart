import 'dart:io';

import 'package:flutter/foundation.dart';

/// Cross-platform single-instance lock for desktop, with no native dependency.
///
/// The first instance binds a fixed loopback port and holds it for the life of
/// the process. A later launch fails to bind (the port is taken), pings the
/// primary so it can surface its window — which may be hidden in the tray — and
/// then exits. A pure-Dart socket works identically on Windows/macOS/Linux.
class SingleInstanceGuard {
  SingleInstanceGuard._();

  /// App-specific high port used as the lock. Collision with an unrelated app
  /// is unlikely; if it happens we fall back to allowing the launch.
  static const int _port = 47923;

  // Kept alive for the process lifetime so the lock isn't released early.
  static ServerSocket? _server;

  /// Returns `true` if this is the primary (and only) instance and startup
  /// should continue; `false` if another instance already holds the lock — the
  /// caller must exit immediately. [onActivate] fires on the primary whenever a
  /// later launch attempt pings it.
  static Future<bool> ensureSingle({
    required Future<void> Function() onActivate,
  }) async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _port,
        shared: false,
      );
      _server!.listen((socket) async {
        socket.destroy();
        try {
          await onActivate();
        } catch (e) {
          debugPrint('SingleInstance: onActivate failed: $e');
        }
      });
      return true;
    } on SocketException {
      // Port already bound → another instance owns the lock. Ping it so it can
      // surface, then tell the caller to bail.
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _port,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
      } catch (e) {
        debugPrint('SingleInstance: failed to ping primary: $e');
      }
      return false;
    } catch (e) {
      // Any other failure must never block startup over a lock hiccup.
      debugPrint('SingleInstance: guard error, allowing launch: $e');
      return true;
    }
  }
}
