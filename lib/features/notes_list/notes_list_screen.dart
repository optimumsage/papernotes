import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/note.dart';
import '../../providers/providers.dart';
import 'notes_empty.dart';
import 'notes_scaffold.dart';
import 'notes_view.dart';

class NotesListScreen extends ConsumerWidget {
  const NotesListScreen({super.key});

  void _openNew(BuildContext context, WidgetRef ref, NoteType type) {
    // Pre-generate the id so the editor owns a real, unique note from the start.
    final id = const Uuid().v4();
    // New notes inherit the folder currently being viewed (if any).
    final folderId = ref.read(selectedFolderProvider);
    final folderParam = folderId == null ? '' : '&folder=$folderId';
    context.push('/editor/$id?new=1&type=${type.name}$folderParam');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(filteredNotesProvider);
    final isLoading =
        ref.watch(activeNotesProvider).isLoading && notes.isEmpty;
    final searching = ref.watch(searchQueryProvider).isNotEmpty;
    final folder = ref.watch(selectedFolderObjectProvider);

    // Manual cloud-sync action, shown only when Drive is connected.
    final driveConnected = ref.watch(settingsControllerProvider
        .select((s) => s.syncEnabled && s.signedIn));
    final syncing = ref.watch(
        syncControllerProvider.select((s) => s.phase == SyncPhase.running));

    return NotesScaffold(
      route: '/',
      title: folder?.name ?? 'PaperNotes',
      extraActions: [
        if (driveConnected)
          IconButton(
            tooltip: syncing ? 'Syncing…' : 'Sync now',
            onPressed: syncing
                ? null
                : () => ref.read(syncControllerProvider.notifier).syncNow(),
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync_outlined),
          ),
      ],
      floatingActionButton: _CreateFab(
        onSelect: (type) => _openNew(context, ref, type),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : notes.isEmpty
              ? NotesEmpty(
                  icon: searching
                      ? Icons.search_off_rounded
                      : (folder != null
                          ? Icons.folder_open_outlined
                          : Icons.note_alt_outlined),
                  title: searching
                      ? 'No matching notes'
                      : (folder != null
                          ? 'No notes in "${folder.name}"'
                          : 'No notes yet'),
                  subtitle: searching
                      ? null
                      : (folder != null
                          ? 'Tap + to add one, or move notes into this folder'
                          : 'Tap + to create your first note'),
                )
              : NotesView(notes: notes, mode: NotesViewMode.active),
    );
  }
}

/// Expandable FAB offering "New note" and "New checklist".
class _CreateFab extends StatelessWidget {
  const _CreateFab({required this.onSelect});
  final void Function(NoteType) onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'fab-checklist',
          tooltip: 'New checklist',
          onPressed: () => onSelect(NoteType.checklist),
          child: const Icon(Icons.checklist_rounded),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'fab-note',
          onPressed: () => onSelect(NoteType.note),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Note'),
        ),
      ],
    );
  }
}
