import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../notes_list/notes_empty.dart';
import '../notes_list/notes_scaffold.dart';
import '../notes_list/notes_view.dart';

class ArchiveScreen extends ConsumerWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(filteredArchivedProvider);
    final isLoading =
        ref.watch(archivedNotesProvider).isLoading && notes.isEmpty;

    return NotesScaffold(
      route: '/archive',
      title: 'Archive',
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : notes.isEmpty
              ? const NotesEmpty(
                  icon: Icons.archive_outlined,
                  title: 'Nothing archived',
                  subtitle: 'Archived notes appear here',
                )
              : NotesView(notes: notes, mode: NotesViewMode.archive),
    );
  }
}
