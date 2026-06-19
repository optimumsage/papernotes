import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models/note.dart';
import '../router.dart';

/// Desktop system-tray integration. Adds a tray icon with an Open / Add note /
/// Quit menu and makes the window's close button hide the app to the tray
/// instead of quitting it — only "Quit" actually exits.
class TrayService with TrayListener, WindowListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  static const _uuid = Uuid();
  bool _initialized = false;

  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> init() async {
    if (_initialized || !isSupported) return;
    _initialized = true;

    try {
      windowManager.addListener(this);
      trayManager.addListener(this);

      // Windows needs an .ico; macOS/Linux use the PNG.
      final iconPath =
          Platform.isWindows ? 'assets/icon/tray.ico' : 'assets/icon/tray.png';
      await trayManager.setIcon(iconPath);
      if (!Platform.isLinux) {
        await trayManager.setToolTip('PaperNotes');
      }
      await trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: 'open', label: 'Open'),
          MenuItem(key: 'add_note', label: 'Add note'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ]),
      );

      // Only now that the tray exists do we intercept window close → hide.
      await windowManager.setPreventClose(true);
    } catch (e) {
      // Tray setup failed — leave normal close behavior so the window can still
      // be closed/quit, and don't leave a dangling listener prevention.
      debugPrint('TrayService init failed: $e');
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      _initialized = false;
    }
  }

  // ---- Tray events ----

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _showWindow();
      case 'add_note':
        _addNote();
      case 'quit':
        _quit();
    }
  }

  // ---- Window events ----

  @override
  void onWindowClose() async {
    // The close button hides to the tray; the app keeps running.
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  // ---- Actions ----

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _addNote() async {
    await _showWindow();
    final id = _uuid.v4();
    appRouter.push('/editor/$id?new=1&type=${NoteType.note.name}');
  }

  Future<void> _quit() async {
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
  }
}
