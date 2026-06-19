import 'package:flutter/material.dart';

/// Shows a transient SnackBar, replacing any currently-visible one so messages
/// never queue up and appear "stuck". Auto-dismisses after [duration].
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 3),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(content: Text(message), action: action, duration: duration),
  );
}
