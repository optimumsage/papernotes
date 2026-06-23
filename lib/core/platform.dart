import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// True on the desktop platforms that get a window, tray, single-instance lock
/// and launch-at-startup support.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// True on Android — gates the configurable note swipe actions, which only
/// make sense for a touch device with edge-swipe gestures.
bool get isAndroidPlatform => !kIsWeb && Platform.isAndroid;
