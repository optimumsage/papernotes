import 'dart:async';

import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/auth/app_lock_service.dart';
import 'desktop/tray_service.dart';
import 'features/app_lock/app_lock_screen.dart';
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
  // When the app was last backgrounded/minimized — used to decide, on resume,
  // whether enough time has elapsed to auto-lock.
  DateTime? _backgroundedAt;

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
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Record the moment the app left the foreground (only the first such
        // transition matters — `??=` so inactive→paused keeps the earliest
        // time). `inactive` is included so desktop focus-loss / tray-hide,
        // which don't emit paused/hidden, still start the auto-lock clock.
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        _maybeSync();
        _maybeAutoLock();
        _backgroundedAt = null;
      default:
        break;
    }
  }

  /// On resume, lock the app if App Lock is on and it was backgrounded for
  /// longer than the configured auto-lock interval.
  void _maybeAutoLock() {
    final backgroundedAt = _backgroundedAt;
    if (backgroundedAt == null) return;
    final settings = ref.read(settingsControllerProvider);
    final lock = ref.read(appLockControllerProvider);
    if (!settings.appLockEnabled || lock.locked) return;
    if (AppLockService.shouldAutoLock(
      autoLockMinutes: settings.appLockAutoLockMinutes,
      elapsed: DateTime.now().difference(backgroundedAt),
    )) {
      ref.read(appLockControllerProvider.notifier).lock();
    }
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
    // App-lock (privacy) gate — the outer of the two gates: authenticate to open
    // the app, then it may still need the encryption master key underneath.
    final appLocked = ref.watch(
      appLockControllerProvider.select((s) => s.locked),
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
          child: appLocked
              ? const AppLockScreen()
              : needsUnlock
                  ? const UnlockScreen()
                  : (child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
