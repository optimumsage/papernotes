import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/note.dart';
import '../../providers/providers.dart';
import '../editor/color_picker.dart';
import 'notes_view.dart';

/// Logical actions a note context menu can offer.
enum _NoteAction { pin, unpin, color, archive, unarchive, trash, restore, deleteForever }

class _ActionSpec {
  final _NoteAction action;
  final IconData icon;
  final String label;
  final bool destructive;
  const _ActionSpec(this.action, this.icon, this.label,
      {this.destructive = false});
}

List<_ActionSpec> _specsFor(Note note, NotesViewMode mode) {
  switch (mode) {
    case NotesViewMode.active:
      return [
        note.pinned
            ? const _ActionSpec(_NoteAction.unpin, Icons.push_pin_outlined, 'Unpin')
            : const _ActionSpec(_NoteAction.pin, Icons.push_pin, 'Pin'),
        const _ActionSpec(_NoteAction.color, Icons.palette_outlined, 'Color…'),
        const _ActionSpec(_NoteAction.archive, Icons.archive_outlined, 'Archive'),
        const _ActionSpec(_NoteAction.trash, Icons.delete_outline, 'Delete',
            destructive: true),
      ];
    case NotesViewMode.archive:
      return [
        const _ActionSpec(_NoteAction.unarchive, Icons.unarchive_outlined, 'Unarchive'),
        const _ActionSpec(_NoteAction.color, Icons.palette_outlined, 'Color…'),
        const _ActionSpec(_NoteAction.trash, Icons.delete_outline, 'Delete',
            destructive: true),
      ];
    case NotesViewMode.trash:
      return [
        const _ActionSpec(_NoteAction.restore, Icons.restore_from_trash_outlined, 'Restore'),
        const _ActionSpec(_NoteAction.deleteForever, Icons.delete_forever_outlined,
            'Delete permanently',
            destructive: true),
      ];
  }
}

/// Popup menu anchored at [position] — used for desktop right-click and mobile
/// long-press.
Future<void> showNoteMenu(BuildContext context, WidgetRef ref, Offset position,
    Note note, NotesViewMode mode) async {
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final theme = Theme.of(context);
  final specs = _specsFor(note, mode);

  final selected = await showMenu<_NoteAction>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(40, 40),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final s in specs)
        PopupMenuItem(
          value: s.action,
          child: Row(
            children: [
              Icon(s.icon,
                  size: 20,
                  color: s.destructive ? theme.colorScheme.error : null),
              const SizedBox(width: 12),
              Text(s.label,
                  style: s.destructive
                      ? TextStyle(color: theme.colorScheme.error)
                      : null),
            ],
          ),
        ),
    ],
  );
  if (selected != null && context.mounted) {
    await _run(context, ref, selected, note);
  }
}

/// Bottom sheet variant — used when a trashed note is tapped (mobile-friendly).
Future<void> showNoteActionsSheet(
    BuildContext context, WidgetRef ref, Note note, NotesViewMode mode) async {
  final specs = _specsFor(note, mode);
  final theme = Theme.of(context);

  final selected = await showModalBottomSheet<_NoteAction>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in specs)
            ListTile(
              leading: Icon(s.icon,
                  color: s.destructive ? theme.colorScheme.error : null),
              title: Text(s.label,
                  style: s.destructive
                      ? TextStyle(color: theme.colorScheme.error)
                      : null),
              onTap: () => Navigator.pop(ctx, s.action),
            ),
        ],
      ),
    ),
  );
  if (selected != null && context.mounted) {
    await _run(context, ref, selected, note);
  }
}

Future<void> _run(BuildContext context, WidgetRef ref, _NoteAction action,
    Note note) async {
  final repo = ref.read(noteRepositoryProvider);
  final messenger = ScaffoldMessenger.of(context);

  switch (action) {
    case _NoteAction.pin:
      await repo.setPinned(note.id, true);
    case _NoteAction.unpin:
      await repo.setPinned(note.id, false);
    case _NoteAction.color:
      if (context.mounted) {
        await ColorPickerSheet.show(
          context,
          selected: note.color,
          onPick: (c) => repo.setColor(note.id, c),
        );
      }
    case _NoteAction.archive:
      await repo.archive(note.id);
      messenger.showSnackBar(SnackBar(
        content: const Text('Archived'),
        action: SnackBarAction(
            label: 'Undo', onPressed: () => repo.unarchive(note.id)),
      ));
    case _NoteAction.unarchive:
      await repo.unarchive(note.id);
    case _NoteAction.trash:
      await repo.moveToTrash(note.id);
      messenger.showSnackBar(SnackBar(
        content: const Text('Moved to Trash'),
        action: SnackBarAction(
            label: 'Undo', onPressed: () => repo.restore(note.id)),
      ));
    case _NoteAction.restore:
      await repo.restore(note.id);
    case _NoteAction.deleteForever:
      final confirm = ref.read(settingsControllerProvider).confirmDelete;
      var ok = true;
      if (confirm && context.mounted) {
        ok = await _confirmDelete(context) ?? false;
      }
      if (ok) await repo.deletePermanently(note.id);
  }
}

Future<bool?> _confirmDelete(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete permanently?'),
      content: const Text('This note will be permanently deleted.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete')),
      ],
    ),
  );
}
