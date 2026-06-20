import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/note.dart';

/// Foreground-service entry point for locked "pinned" reminders on Android.
/// Must be a top-level function so it survives release-mode tree-shaking.
@pragma('vm:entry-point')
void pinnedReminderCallback() {
  FlutterForegroundTask.setTaskHandler(_PinnedReminderTaskHandler());
}

/// The pinned-reminder service only needs to keep its notification alive; it
/// does no periodic work. Tapping the notification opens the app.
class _PinnedReminderTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

/// Cross-platform reminder notifications.
///
/// - **Android**: native scheduling via `flutter_local_notifications`. Timed
///   alarms use exact alarms so they fire even when the app is closed; "pinned"
///   reminders show an ongoing status-bar notification.
/// - **macOS / Linux**: `flutter_local_notifications` for display; timing is
///   driven by the in-app scheduler (the app stays alive in the tray).
/// - **Windows**: `local_notifier` toasts; timing driven by the in-app scheduler.
///
/// All calls are best-effort and never throw — notifications must not be able to
/// crash note editing or app startup.
class ReminderService {
  ReminderService();

  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  bool get ready => _ready;

  bool get _useFln =>
      !kIsWeb && (Platform.isAndroid || Platform.isMacOS || Platform.isLinux);
  bool get _useLocalNotifier => !kIsWeb && Platform.isWindows;

  /// True where the OS can fire a scheduled reminder while the app is dead.
  /// Elsewhere the in-app scheduler keeps timers and calls [showNow].
  bool get nativeScheduling => !kIsWeb && Platform.isAndroid;

  /// On Android, "pinned" reminders are backed by a foreground service so the
  /// OS keeps them locked in the status bar (un-swipeable even on Android 14+,
  /// which lets users dismiss ordinary ongoing notifications). Other platforms
  /// keep using an ongoing notification driven by the in-app reconciler.
  bool get usesForegroundPinned => !kIsWeb && Platform.isAndroid;

  Future<void> init() async {
    if (_ready) return;
    try {
      if (_useFln) {
        tzdata.initializeTimeZones();
        try {
          final info = await FlutterTimezone.getLocalTimezone();
          tz.setLocalLocation(tz.getLocation(info.identifier));
        } catch (_) {
          // Leave tz.local as UTC if the platform zone can't be resolved.
        }
        await _fln.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            macOS: DarwinInitializationSettings(),
            linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          ),
        );
        await _requestPermissions();
        if (usesForegroundPinned) _initForegroundService();
      } else if (_useLocalNotifier) {
        await localNotifier.setup(appName: 'PaperNotes');
      }
      _ready = true;
    } catch (e) {
      debugPrint('ReminderService init failed: $e');
    }
  }

  Future<void> _requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final android = _fln.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await android?.requestNotificationsPermission();
        await android?.requestExactAlarmsPermission();
      } else if (Platform.isMacOS) {
        await _fln
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugPrint('ReminderService permission request failed: $e');
    }
  }

  /// Stable, positive notification id derived from a note's UUID.
  int notifId(String noteId) => noteId.hashCode & 0x7fffffff;

  String _title(Note note) => note.hasTitle ? note.title!.trim() : 'Reminder';

  String _body(Note note) {
    if (note.isChecklist) {
      final texts = note.items
          .map((i) => i.text.trim())
          .where((t) => t.isNotEmpty)
          .take(3);
      return texts.isEmpty ? 'Checklist reminder' : texts.join(', ');
    }
    final body = (note.body ?? '').trim();
    return body.isEmpty ? 'Note reminder' : body;
  }

  NotificationDetails _details({required bool ongoing}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'reminders',
        'Reminders',
        channelDescription: 'Note reminders',
        importance: Importance.max,
        priority: Priority.high,
        ongoing: ongoing,
        autoCancel: !ongoing,
      ),
      macOS: const DarwinNotificationDetails(),
      linux: const LinuxNotificationDetails(),
    );
  }

  /// Show a reminder immediately. [ongoing] keeps it pinned in the status bar
  /// (Android); ignored where the platform doesn't support it.
  Future<void> showNow(Note note, {bool ongoing = false}) async {
    if (!_ready) return;
    final title = _title(note);
    final body = _body(note);
    try {
      if (_useFln) {
        await _fln.show(
          id: notifId(note.id),
          title: title,
          body: body,
          notificationDetails: _details(ongoing: ongoing),
          payload: note.id,
        );
      } else if (_useLocalNotifier) {
        await LocalNotification(title: title, body: body).show();
      }
    } catch (e) {
      debugPrint('ReminderService showNow failed: $e');
    }
  }

  /// Schedule a note's timed alarm at the OS level (Android only). A no-op
  /// elsewhere — the in-app scheduler handles timing on desktop.
  Future<void> scheduleExact(Note note) async {
    if (!_ready || !nativeScheduling) return;
    final at = note.reminderAt;
    if (at == null) return;
    final when = tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, at);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) return; // past-due: skip
    try {
      await _fln.zonedSchedule(
        id: notifId(note.id),
        title: _title(note),
        body: _body(note),
        scheduledDate: when,
        notificationDetails: _details(ongoing: false),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: note.id,
      );
    } catch (e) {
      debugPrint('ReminderService scheduleExact failed: $e');
    }
  }

  /// Cancel any shown/scheduled reminder for [noteId].
  Future<void> cancel(String noteId) async {
    if (!_ready) return;
    try {
      if (_useFln) await _fln.cancel(id: notifId(noteId));
      // local_notifier toasts auto-dismiss; nothing to cancel on Windows.
    } catch (e) {
      debugPrint('ReminderService cancel failed: $e');
    }
  }

  void _initForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pinned_reminders',
        channelName: 'Pinned reminders',
        channelDescription: 'Locked note reminders kept in the status bar',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Notification-only: no periodic event, but keep it alive across reboots
        // and updates so a pinned reminder stays put until the user clears it.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  }

  /// Android: reconcile the locked-reminder foreground service to [pinned].
  /// Empty list stops the service; otherwise the service runs with one
  /// consolidated, un-swipeable notification. No-op off Android.
  Future<void> syncPinned(List<Note> pinned) async {
    if (!_ready || !usesForegroundPinned) return;
    try {
      if (pinned.isEmpty) {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
        return;
      }
      // Clear any legacy per-note ongoing notifications shown by older builds
      // so they don't linger alongside the service notification.
      for (final n in pinned) {
        await _fln.cancel(id: notifId(n.id));
      }
      final (title, text) = _pinnedContent(pinned);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceTypes: [ForegroundServiceTypes.specialUse],
          notificationTitle: title,
          notificationText: text,
          callback: pinnedReminderCallback,
        );
      }
    } catch (e) {
      debugPrint('ReminderService syncPinned failed: $e');
    }
  }

  /// Title/body for the consolidated pinned-reminder notification.
  (String, String) _pinnedContent(List<Note> pinned) {
    if (pinned.length == 1) {
      final n = pinned.first;
      return (_title(n), _body(n));
    }
    final titles = pinned.map(_title).take(5).join(', ');
    return ('${pinned.length} pinned reminders', titles);
  }
}
