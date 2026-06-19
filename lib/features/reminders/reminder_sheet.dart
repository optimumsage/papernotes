import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_snackbar.dart';
import '../../core/date_format.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';

/// Bottom sheet for setting or clearing a note's reminder. Offers a timed alarm
/// (date + time picker) and a "pin to status bar" persistent reminder.
class ReminderSheet {
  const ReminderSheet._();

  static Future<void> show(
      BuildContext context, WidgetRef ref, Note note) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Reminder',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            if (note.hasReminder)
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(_currentLabel(note)),
                subtitle: const Text('Currently set'),
                enabled: false,
              ),
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Time alarm…'),
              subtitle: const Text('Notify at a chosen date and time'),
              onTap: () => Navigator.pop(ctx, 'alarm'),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Pin to status bar'),
              subtitle: const Text('Keep a persistent notification'),
              onTap: () => Navigator.pop(ctx, 'pinned'),
            ),
            if (note.hasReminder)
              ListTile(
                leading: Icon(Icons.notifications_off_outlined,
                    color: Theme.of(ctx).colorScheme.error),
                title: Text('Remove reminder',
                    style:
                        TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );

    if (choice == null || !context.mounted) return;
    final repo = ref.read(noteRepositoryProvider);

    switch (choice) {
      case 'alarm':
        final at = await _pickDateTime(context);
        if (at == null) return;
        if (at <= DateTime.now().millisecondsSinceEpoch) {
          if (context.mounted) {
            showAppSnackBar(context, 'Pick a time in the future');
          }
          return;
        }
        await repo.setReminder(note.id, ReminderType.alarm, at);
        if (context.mounted) {
          showAppSnackBar(context, 'Reminder set for ${_when(at)}');
        }
      case 'pinned':
        await repo.setReminder(note.id, ReminderType.pinned, null);
        if (context.mounted) showAppSnackBar(context, 'Pinned to status bar');
      case 'remove':
        await repo.setReminder(note.id, ReminderType.none, null);
        if (context.mounted) showAppSnackBar(context, 'Reminder removed');
    }
  }

  /// Date + time label for a reminder timestamp, e.g. "3 Jun 2026 · 14:05".
  static String _when(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${fullDate(epochMs)} · $hh:$mm';
  }

  static String _currentLabel(Note note) {
    switch (note.reminderType) {
      case ReminderType.alarm:
        return note.reminderAt != null
            ? 'Alarm · ${_when(note.reminderAt!)}'
            : 'Alarm';
      case ReminderType.pinned:
        return 'Pinned to status bar';
      case ReminderType.none:
        return 'No reminder';
    }
  }

  /// Pick a future date + time, returning epoch ms (or null if cancelled).
  static Future<int?> _pickDateTime(BuildContext context) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
    );
    if (time == null) return null;
    final when = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    return when.millisecondsSinceEpoch;
  }
}
