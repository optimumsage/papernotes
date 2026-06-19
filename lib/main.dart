import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/local/database.dart';
import 'data/reminders/reminder_service.dart';
import 'data/settings_service.dart';
import 'providers/providers.dart';

/// Desktop platforms that get a window + system tray.
bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On desktop, take over window management so closing the window can hide the
  // app to the system tray instead of quitting it. `setPreventClose(true)` is
  // deferred to TrayService.init() so it's only enabled once a tray actually
  // exists to reopen the window from.
  if (_isDesktop) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      center: true,
      title: 'PaperNotes',
    );
    unawaitedShow(windowOptions);
  }

  // Bootstrap the singletons the provider graph depends on.
  final prefs = await SharedPreferences.getInstance();
  final database = AppDatabase();
  final initialSettings = await SettingsService(prefs).load();

  // Initialize notifications up front so the reminder reconciler is ready
  // before the first notes stream emission.
  final reminderService = ReminderService();
  await reminderService.init();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
        initialSettingsProvider.overrideWithValue(initialSettings),
        reminderServiceProvider.overrideWithValue(reminderService),
      ],
      child: const PaperNotesApp(),
    ),
  );
}

/// Show + focus the window once it's ready (kept separate so `main` stays linear).
void unawaitedShow(WindowOptions options) {
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
