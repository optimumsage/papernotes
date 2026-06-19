import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';

import '../../core/note_sort.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';
import 'note_card.dart';
import 'note_context_menu.dart';

/// Which collection is being shown — drives the context-menu actions and the
/// tap behavior of each card.
enum NotesViewMode { active, archive, trash }

/// Shared notes renderer used by the Notes, Archive, and Trash screens. Lays
/// out cards as a masonry grid or a single-column list per the user's
/// preference, and wires right-click (desktop) / long-press (Android) to the
/// per-mode context menu.
class NotesView extends ConsumerWidget {
  const NotesView({super.key, required this.notes, required this.mode});

  final List<Note> notes;
  final NotesViewMode mode;

  void _onCardTap(BuildContext context, WidgetRef ref, Note note) {
    // Active/archived notes open in the editor; trashed notes aren't editable
    // until restored, so a tap surfaces their restore/delete actions instead.
    if (mode == NotesViewMode.trash) {
      showNoteActionsSheet(context, ref, note, mode);
    } else {
      context.push('/editor/${note.id}');
    }
  }

  Widget _wrap(BuildContext context, WidgetRef ref, Note note) {
    // InkWell inside NoteCard claims normal taps; secondary-tap and long-press
    // fall through to this GestureDetector and open the context menu at the
    // pointer position.
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          showNoteMenu(context, ref, d.globalPosition, note, mode),
      onLongPressStart: (d) =>
          showNoteMenu(context, ref, d.globalPosition, note, mode),
      child: Hero(
        tag: 'note-${note.id}',
        child: Material(
          type: MaterialType.transparency,
          child: NoteCard(
            note: note,
            onTap: () => _onCardTap(context, ref, note),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewStyle =
        ref.watch(settingsControllerProvider.select((s) => s.viewStyle));

    if (viewStyle == ViewStyle.list) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
        itemCount: notes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _wrap(context, ref, notes[i]),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / 260).floor().clamp(2, 6);
    return MasonryGridView.count(
      crossAxisCount: columns,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      itemCount: notes.length,
      itemBuilder: (context, i) => _wrap(context, ref, notes[i]),
    );
  }
}
