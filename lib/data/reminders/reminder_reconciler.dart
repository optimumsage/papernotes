import 'dart:async';

import '../models/note.dart';
import 'reminder_service.dart';

/// Keeps OS reminders in sync with notes' reminder fields. Driven by the active
/// notes stream so create / edit / delete and remote sync all converge here in
/// one place.
///
/// On Android, timed alarms are handed to the OS ([ReminderService.scheduleExact])
/// and fire even when the app is closed. On desktop the app stays alive in the
/// tray, so timing is driven by in-app [Timer]s; a fired alarm is consumed via
/// [onFired] so it doesn't re-trigger on every launch.
class ReminderReconciler {
  ReminderReconciler(this._service, {this.onFired});

  final ReminderService _service;

  /// Called when a timed alarm has fired (desktop) or is found already past
  /// (any platform) so the caller can clear the note's reminder.
  final void Function(String noteId)? onFired;

  // Last-applied "type|at" signature per note — avoids redundant reschedules.
  final Map<String, String> _applied = {};
  // Desktop in-app timers (one per pending alarm).
  final Map<String, Timer> _timers = {};
  // Aggregate signature of the Android foreground-service pinned set.
  String _pinnedSig = '';

  String _sig(Note n) => '${n.reminderType.name}|${n.reminderAt ?? 0}';

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Pinned notes handled by the Android foreground service (not the per-note
  /// FLN path) — kept out of [_applied] so the two paths can't double up.
  bool _isForegroundPinned(Note n) =>
      _service.usesForegroundPinned && n.reminderType == ReminderType.pinned;

  void reconcile(List<Note> notes) {
    // Wait until notifications are initialized; a later stream emission (or the
    // fireImmediately call after init) will drive the first real reconcile.
    if (!_service.ready) return;

    final desired = <String, Note>{
      for (final n in notes)
        if (n.hasReminder && !n.deleted && !n.isTrashed) n.id: n,
    };

    // Android: pinned reminders are backed by one foreground service so the OS
    // keeps them locked. Reconcile the whole set together, only when it changes.
    if (_service.usesForegroundPinned) {
      final pinned = desired.values
          .where((n) => n.reminderType == ReminderType.pinned)
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final sig = pinned.map((n) => '${n.id}:${n.updatedAt}').join('|');
      if (sig != _pinnedSig) {
        _pinnedSig = sig;
        _service.syncPinned(pinned);
      }
    }

    // Clear reminders for notes that disappeared, lost their reminder, or moved
    // onto the foreground-service path (so a stale alarm/timer is torn down).
    for (final id in _applied.keys.toList()) {
      final note = desired[id];
      if (note == null || _isForegroundPinned(note)) _clear(id);
    }

    // Apply new or changed reminders (skipping the foreground-pinned set).
    for (final note in desired.values) {
      if (_isForegroundPinned(note)) continue;
      final sig = _sig(note);
      if (_applied[note.id] == sig) continue;
      _apply(note);
      _applied[note.id] = sig;
    }
  }

  void _apply(Note note) {
    // Reset any prior OS state / timer for this note.
    _service.cancel(note.id);
    _timers.remove(note.id)?.cancel();

    if (note.reminderType == ReminderType.pinned) {
      _service.showNow(note, ongoing: true);
      return;
    }

    // ReminderType.alarm
    final at = note.reminderAt;
    if (at == null) return;

    if (_service.nativeScheduling) {
      final delay = at - _now;
      if (delay <= 0) {
        // Native alarm already fired while the app was closed — consume it.
        onFired?.call(note.id);
      } else {
        _service.scheduleExact(note);
      }
      return;
    }

    // Desktop: drive timing ourselves (app kept alive by the tray).
    final delay = at - _now;
    if (delay <= 0) {
      _service.showNow(note); // catch-up
      onFired?.call(note.id);
    } else {
      _timers[note.id] = Timer(Duration(milliseconds: delay), () {
        _timers.remove(note.id);
        _service.showNow(note);
        onFired?.call(note.id);
      });
    }
  }

  void _clear(String id) {
    _applied.remove(id);
    _timers.remove(id)?.cancel();
    _service.cancel(id);
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}
