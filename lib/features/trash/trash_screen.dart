import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../notes_list/notes_empty.dart';
import '../notes_list/notes_scaffold.dart';
import '../notes_list/notes_view.dart';

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  Future<void> _emptyTrash(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(noteRepositoryProvider);
    final confirm = ref.read(settingsControllerProvider).confirmDelete;
    final messenger = ScaffoldMessenger.of(context);
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Empty trash?'),
          content: const Text(
              'All notes in Trash will be permanently deleted. This cannot be undone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Empty trash')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await repo.emptyTrash();
    messenger.clearSnackBars();
    messenger.showSnackBar(const SnackBar(
        content: Text('Trash emptied'), duration: Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(filteredTrashedProvider);
    final isLoading =
        ref.watch(trashedNotesProvider).isLoading && notes.isEmpty;
    final retention =
        ref.watch(settingsControllerProvider.select((s) => s.trashRetentionDays));
    final theme = Theme.of(context);

    return NotesScaffold(
      route: '/trash',
      title: 'Trash',
      extraActions: [
        IconButton(
          tooltip: 'Empty trash',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: notes.isEmpty ? null : () => _emptyTrash(context, ref),
        ),
      ],
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : notes.isEmpty
              ? const NotesEmpty(
                  icon: Icons.delete_outline,
                  title: 'Trash is empty',
                  subtitle: 'Deleted notes appear here',
                )
              : Column(
                  children: [
                    if (retention > 0)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Text(
                          'Notes in Trash are deleted after $retention days. Tap a note to restore or delete it.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    Expanded(
                      child: NotesView(notes: notes, mode: NotesViewMode.trash),
                    ),
                  ],
                ),
    );
  }
}
