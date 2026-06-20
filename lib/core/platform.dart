import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// True on the desktop platforms that get a window, tray, single-instance lock
/// and launch-at-startup support.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
