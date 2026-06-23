import 'package:flutter/material.dart';

/// An action that can be bound to a left or right swipe on a note card
/// (Android only). `none` disables that swipe direction.
///
/// `delete` moves the note to Trash (recoverable), matching the context-menu
/// "Delete" action — it is not a permanent delete.
enum SwipeAction { none, delete, pin, archive, reminder, moveToFolder }

extension SwipeActionMeta on SwipeAction {
  String get label => switch (this) {
        SwipeAction.none => 'None',
        SwipeAction.delete => 'Delete',
        SwipeAction.pin => 'Pin',
        SwipeAction.archive => 'Archive',
        SwipeAction.reminder => 'Reminder',
        SwipeAction.moveToFolder => 'Move to folder',
      };

  IconData get icon => switch (this) {
        SwipeAction.none => Icons.block,
        SwipeAction.delete => Icons.delete_outline,
        SwipeAction.pin => Icons.push_pin,
        SwipeAction.archive => Icons.archive_outlined,
        SwipeAction.reminder => Icons.notifications_outlined,
        SwipeAction.moveToFolder => Icons.drive_file_move_outlined,
      };

  /// Destructive swipes (delete) use the error color for the swipe background.
  bool get isDestructive => this == SwipeAction.delete;
}

SwipeAction swipeActionFromName(String? name) =>
    SwipeAction.values.firstWhere((a) => a.name == name,
        orElse: () => SwipeAction.none);
