import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_snackbar.dart';
import '../../core/note_share.dart';
import '../../data/models/folder.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';
import '../editor/color_picker.dart';
import '../reminders/reminder_sheet.dart';
import 'notes_view.dart';

/// Logical actions a note context menu can offer.
enum _NoteAction {
  pin,
  unpin,
  color,
  moveToFolder,
  reminder,
  share,
  archive,
  unarchive,
  trash,
  restore,
  deleteForever,
}

class _ActionSpec {
  final _NoteAction action;
  final IconData icon;
  final String label;
  final bool destructive;
  const _ActionSpec(this.action, this.icon, this.label,
      {this.destructive = false});
}

/// Reminder entry whose label reflects whether one is already set.
_ActionSpec _reminderSpec(Note note) => _ActionSpec(
      _NoteAction.reminder,
      note.hasReminder
          ? Icons.notifications_active_outlined
          : Icons.notifications_outlined,
      note.hasReminder ? 'Edit reminder…' : 'Reminder…',
    );

List<_ActionSpec> _specsFor(Note note, NotesViewMode mode) {
  switch (mode) {
    case NotesViewMode.active:
      return [
        note.pinned
            ? const _ActionSpec(_NoteAction.unpin, Icons.push_pin_outlined, 'Unpin')
            : const _ActionSpec(_NoteAction.pin, Icons.push_pin, 'Pin'),
        const _ActionSpec(_NoteAction.color, Icons.palette_outlined, 'Color…'),
        const _ActionSpec(_NoteAction.moveToFolder,
            Icons.drive_file_move_outlined, 'Move to folder…'),
        _reminderSpec(note),
        const _ActionSpec(_NoteAction.share, Icons.share_outlined, 'Share'),
        const _ActionSpec(_NoteAction.archive, Icons.archive_outlined, 'Archive'),
        const _ActionSpec(_NoteAction.trash, Icons.delete_outline, 'Delete',
            destructive: true),
      ];
    case NotesViewMode.archive:
      return [
        const _ActionSpec(_NoteAction.unarchive, Icons.unarchive_outlined, 'Unarchive'),
        const _ActionSpec(_NoteAction.color, Icons.palette_outlined, 'Color…'),
        const _ActionSpec(_NoteAction.moveToFolder,
            Icons.drive_file_move_outlined, 'Move to folder…'),
        // Reminders only fire for active notes, so they aren't offered here.
        const _ActionSpec(_NoteAction.share, Icons.share_outlined, 'Share'),
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
    case _NoteAction.moveToFolder:
      if (context.mounted) await _moveToFolder(context, ref, note);
    case _NoteAction.reminder:
      if (context.mounted) await ReminderSheet.show(context, ref, note);
    case _NoteAction.share:
      final shared = await shareNote(note);
      if (!shared && context.mounted) {
        showAppSnackBar(context, 'Copied to clipboard');
      }
    case _NoteAction.archive:
      await repo.archive(note.id);
      if (context.mounted) {
        showAppSnackBar(context, 'Archived',
            action: SnackBarAction(
                label: 'Undo', onPressed: () => repo.unarchive(note.id)));
      }
    case _NoteAction.unarchive:
      await repo.unarchive(note.id);
    case _NoteAction.trash:
      await repo.moveToTrash(note.id);
      if (context.mounted) {
        showAppSnackBar(context, 'Moved to Trash',
            action: SnackBarAction(
                label: 'Undo', onPressed: () => repo.restore(note.id)));
      }
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

/// Bottom-sheet folder picker — the touch-friendly path for filing a note
/// (desktop also has drag-and-drop). Lets the user pick an existing folder,
/// create a new one, or remove the note from its current folder.
Future<void> _moveToFolder(
    BuildContext context, WidgetRef ref, Note note) async {
  final folders = ref.read(foldersProvider).value ?? const <Folder>[];
  final repo = ref.read(noteRepositoryProvider);

  final selected = await showModalBottomSheet<Object>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Move to folder',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          if (note.folderId != null)
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('Remove from folder'),
              onTap: () => Navigator.pop(ctx, '__none__'),
            ),
          for (final f in folders)
            ListTile(
              leading: Icon(note.folderId == f.id
                  ? Icons.folder
                  : Icons.folder_outlined),
              title: Text(f.name),
              trailing: note.folderId == f.id
                  ? const Icon(Icons.check, size: 20)
                  : null,
              onTap: () => Navigator.pop(ctx, f),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder…'),
            onTap: () => Navigator.pop(ctx, '__new__'),
          ),
        ],
      ),
    ),
  );

  if (selected == null) return;
  if (selected == '__none__') {
    await repo.setFolder(note.id, null);
  } else if (selected == '__new__') {
    if (!context.mounted) return;
    final name = await _promptFolderName(context);
    if (name == null || name.isEmpty) return;
    final folder = await ref.read(folderRepositoryProvider).createFolder(name);
    await repo.setFolder(note.id, folder.id);
    if (context.mounted) showAppSnackBar(context, 'Moved to "$name"');
  } else if (selected is Folder) {
    await repo.setFolder(note.id, selected.id);
    if (context.mounted) showAppSnackBar(context, 'Moved to "${selected.name}"');
  }
}

Future<String?> _promptFolderName(BuildContext context) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Folder name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
  } finally {
    controller.dispose();
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
