import 'dart:async';

import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'desktop/tray_service.dart';
import 'features/encryption/unlock_screen.dart';
import 'providers/providers.dart';
import 'router.dart';

class PaperNotesApp extends ConsumerStatefulWidget {
  const PaperNotesApp({super.key});

  @override
  ConsumerState<PaperNotesApp> createState() => _PaperNotesAppState();
}

class _PaperNotesAppState extends ConsumerState<PaperNotesApp>
    with WidgetsBindingObserver {
  Timer? _syncTimer;
  int _timerMinutes = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onLaunch();
      _rebuildSyncTimer();
      // Desktop: set up the system tray + hide-on-close behavior.
      if (TrayService.isSupported) unawaited(TrayService.instance.init());
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeSync();
  }

  /// One-time launch maintenance: optional sync-on-launch + trash auto-empty.
  void _onLaunch() {
    final settings = ref.read(settingsControllerProvider);
    unawaited(ref
        .read(noteRepositoryProvider)
        .autoEmptyTrash(settings.trashRetentionDays));
    if (settings.syncOnLaunch) _maybeSync();
  }

  /// Recreate the periodic timer when the auto-sync interval changes.
  void _rebuildSyncTimer() {
    final settings = ref.read(settingsControllerProvider);
    if (!settings.autoSyncEnabled) {
      _syncTimer?.cancel();
      _syncTimer = null;
      _timerMinutes = 0;
      return;
    }
    if (_timerMinutes == settings.autoSyncMinutes && _syncTimer != null) return;
    _timerMinutes = settings.autoSyncMinutes;
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
        Duration(minutes: _timerMinutes), (_) => _maybeSync());
  }

  void _maybeSync() {
    final settings = ref.read(settingsControllerProvider);
    if (settings.syncEnabled && settings.signedIn) {
      unawaited(ref.read(syncControllerProvider.notifier).syncNow());
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );
    final fontScale = ref.watch(
      settingsControllerProvider.select((s) => s.fontScale),
    );
    // Gate the whole app behind the unlock screen when encryption is on for the
    // account but this device hasn't entered the master key yet.
    final needsUnlock = ref.watch(
      encryptionControllerProvider.select((s) => s.needsUnlock),
    );
    // Keep the reminder reconciler alive so it watches the notes stream and
    // schedules/cancels OS reminders as notes change.
    ref.watch(reminderReconcilerProvider);
    // Rebuild the sync timer if the interval/toggle changed.
    ref.listen(
      settingsControllerProvider.select(
          (s) => (s.autoSyncEnabled, s.autoSyncMinutes)),
      (_, _) => _rebuildSyncTimer(),
    );

    return MaterialApp.router(
      title: 'PaperNotes',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // Required by the Fleather rich-text editor (selection menu, tooltips).
      localizationsDelegates: const [FleatherLocalizations.delegate],
      routerConfig: appRouter,
      builder: (context, child) {
        // Apply the user's font-size preference app-wide.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(fontScale)),
          child: needsUnlock
              ? const UnlockScreen()
              : (child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
