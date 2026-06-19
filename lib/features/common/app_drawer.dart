import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_snackbar.dart';
import '../../data/models/folder.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';

/// Modal drawer used on narrow (mobile) layouts. Wraps [AppDrawerContent].
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.current});

  /// One of '/', '/archive', '/trash'.
  final String current;

  @override
  Widget build(BuildContext context) {
    return Drawer(child: AppDrawerContent(current: current, inDrawer: true));
  }
}

/// Shared navigation content: Notes / Archive / Trash, the user's folders
/// (tap to filter, drag a note onto one to file it), and Settings. Rendered as
/// a modal [Drawer] on mobile and as a permanent side panel on desktop — the
/// latter keeps folder drop-targets visible while dragging note cards.
class AppDrawerContent extends ConsumerWidget {
  const AppDrawerContent({
    super.key,
    required this.current,
    this.inDrawer = false,
  });

  final String current;

  /// True when hosted inside a modal [Drawer] (mobile): navigation closes it.
  final bool inDrawer;

  void _go(BuildContext context, String route) {
    if (inDrawer) Navigator.pop(context);
    if (current != route) context.go(route);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final folders = ref.watch(foldersProvider).value ?? const [];
    final selectedFolder = ref.watch(selectedFolderProvider);
    final onNotes = current == '/';

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Row(
              children: [
                Icon(Icons.sticky_note_2_rounded,
                    color: theme.colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Text('PaperNotes',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _NavTile(
                  icon: Icons.sticky_note_2_outlined,
                  label: 'Notes',
                  selected: onNotes && selectedFolder == null,
                  onTap: () {
                    ref.read(selectedFolderProvider.notifier).set(null);
                    _go(context, '/');
                  },
                ),
                _NavTile(
                  icon: Icons.archive_outlined,
                  label: 'Archive',
                  selected: current == '/archive',
                  onTap: () => _go(context, '/archive'),
                ),
                _NavTile(
                  icon: Icons.delete_outline,
                  label: 'Trash',
                  selected: current == '/trash',
                  onTap: () => _go(context, '/trash'),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
                  child: Row(
                    children: [
                      Text('Folders',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.add, size: 20),
                        tooltip: 'New folder',
                        onPressed: () => _createFolder(context, ref),
                      ),
                    ],
                  ),
                ),
                if (folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      'No folders yet. Tap + to create one, then drag notes in.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                else
                  for (final folder in folders)
                    _FolderTile(
                      folder: folder,
                      selected: onNotes && selectedFolder == folder.id,
                      onTap: () {
                        ref
                            .read(selectedFolderProvider.notifier)
                            .set(folder.id);
                        _go(context, '/');
                      },
                      onDropNote: (note) async {
                        await ref
                            .read(noteRepositoryProvider)
                            .setFolder(note.id, folder.id);
                        if (context.mounted) {
                          showAppSnackBar(
                              context, 'Moved to "${folder.name}"');
                        }
                      },
                      onRename: () => _renameFolder(context, ref, folder),
                      onDelete: () => _deleteFolder(context, ref, folder),
                    ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              if (inDrawer) Navigator.pop(context);
              context.push('/settings');
            },
          ),
        ],
      ),
    );
  }

  // ---- Folder mutations (dialogs) ----

  Future<void> _createFolder(BuildContext context, WidgetRef ref) async {
    final name = await _promptName(context, title: 'New folder');
    if (name == null || name.isEmpty) return;
    await ref.read(folderRepositoryProvider).createFolder(name);
  }

  Future<void> _renameFolder(
      BuildContext context, WidgetRef ref, Folder folder) async {
    final name =
        await _promptName(context, title: 'Rename folder', initial: folder.name);
    if (name == null || name.isEmpty) return;
    await ref.read(folderRepositoryProvider).renameFolder(folder.id, name);
  }

  Future<void> _deleteFolder(
      BuildContext context, WidgetRef ref, Folder folder) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: const Text(
            'The folder is removed. Notes inside it are kept and become unfiled.'),
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
    if (confirm != true) return;
    // If we were viewing the deleted folder, fall back to all notes.
    if (ref.read(selectedFolderProvider) == folder.id) {
      ref.read(selectedFolderProvider.notifier).set(null);
    }
    await ref.read(folderRepositoryProvider).deleteFolder(folder.id);
  }
}

/// Shared text-prompt dialog for create/rename. Returns the trimmed name, or
/// null if cancelled.
Future<String?> _promptName(BuildContext context,
    {required String title, String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
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
              child: const Text('Save')),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: selected ? theme.colorScheme.primary : null),
      title: Text(label,
          style: TextStyle(
            color: selected ? theme.colorScheme.primary : null,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          )),
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      onTap: onTap,
    );
  }
}

/// A folder row that doubles as a [DragTarget] for note cards (desktop
/// drag-and-drop) and exposes rename/delete via a trailing menu.
class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onDropNote,
    required this.onRename,
    required this.onDelete,
  });

  final Folder folder;
  final bool selected;
  final VoidCallback onTap;
  final Future<void> Function(Note) onDropNote;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<Note>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onDropNote(d.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return ListTile(
          leading: Icon(
            hovering ? Icons.drive_file_move_rounded : Icons.folder_outlined,
            color: (selected || hovering) ? theme.colorScheme.primary : null,
          ),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? theme.colorScheme.primary : null,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          selected: selected,
          selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
          tileColor: hovering
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : null,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
          ),
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Folder options',
            onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
          onTap: onTap,
        );
      },
    );
  }
}
