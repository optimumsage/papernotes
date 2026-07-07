import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/platform.dart';
import 'data/attachments/attachment_store.dart';
import 'data/local/database.dart';
import 'data/reminders/reminder_service.dart';
import 'data/settings_service.dart';
import 'desktop/auto_start.dart';
import 'desktop/single_instance.dart';
import 'providers/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktopPlatform) {
    // Single instance: if another copy already holds the lock, ask it to
    // surface its window (it may be hidden in the tray) and quit this one.
    final primary = await SingleInstanceGuard.ensureSingle(
      onActivate: () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    if (!primary) {
      exit(0);
    }

    // Take over window management so closing the window can hide the app to the
    // system tray instead of quitting it. `setPreventClose(true)` is deferred to
    // TrayService.init() so it's only enabled once a tray exists to reopen from.
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
  final attachmentStore = await AttachmentStore.open();

  // Desktop: if launch-at-login is on, re-apply it so the autostart entry
  // points at the current executable after an update and self-heals if it was
  // removed out of band. Fire-and-forget so it never delays startup.
  if (isDesktopPlatform && initialSettings.launchAtStartup) {
    unawaited(AutoStartService.instance.setEnabled(true));
  }

  // Initialize notifications concurrently with the first frame — init parses
  // the timezone database and, on first Android launch, can block on a
  // permission dialog. The reminder reconciler replays the latest notes once
  // `whenReady` completes, so nothing is missed.
  final reminderService = ReminderService();
  unawaited(reminderService.init());

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
        initialSettingsProvider.overrideWithValue(initialSettings),
        attachmentStoreProvider.overrideWithValue(attachmentStore),
        reminderServiceProvider.overrideWithValue(reminderService),
      ],
      child: const PaperNotesApp(),
    ),
  );

  // Clean up attachment files whose note no longer exists (a permanent delete
  // synced in from another device removes the row without touching this
  // device's files). Best-effort, off the startup path.
  unawaited(_sweepOrphanAttachments(database, attachmentStore));
}

Future<void> _sweepOrphanAttachments(
    AppDatabase database, AttachmentStore store) {
  // Per-directory freshness check (no snapshot): a note created while the
  // sweep runs is seen by the query, so its files are never swept.
  return store.sweepOrphans((noteId) async {
    final row = await database.rawRow(noteId);
    return row != null && !row.deleted;
  });
}

/// Show + focus the window once it's ready (kept separate so `main` stays linear).
void unawaitedShow(WindowOptions options) {
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
