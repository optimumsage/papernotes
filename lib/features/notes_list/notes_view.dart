import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';

import '../../core/note_body.dart';
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

  /// On desktop, dragging a card onto a folder in the side panel files it.
  /// Touch platforms keep scroll gestures and use the "Move to folder" menu
  /// action instead, so Draggable is desktop-only.
  static bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  Widget _wrap(
      BuildContext context, WidgetRef ref, Note note, int previewLines) {
    // InkWell inside NoteCard claims normal taps; secondary-tap and long-press
    // fall through to this GestureDetector and open the context menu at the
    // pointer position.
    final card = GestureDetector(
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
            maxPreviewLines: previewLines,
          ),
        ),
      ),
    );

    if (!_desktop || mode != NotesViewMode.active) return card;

    return Draggable<Note>(
      data: note,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(note: note),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewStyle =
        ref.watch(settingsControllerProvider.select((s) => s.viewStyle));
    final previewLines =
        ref.watch(settingsControllerProvider.select((s) => s.previewLines));

    if (viewStyle == ViewStyle.list) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
        itemCount: notes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _wrap(context, ref, notes[i], previewLines),
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
      itemBuilder: (context, i) => _wrap(context, ref, notes[i], previewLines),
    );
  }
}

/// Compact chip shown under the pointer while dragging a note to a folder.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = plainTextFromBody(note.body).trim();
    final label = note.hasTitle
        ? note.title!.trim()
        : (note.isChecklist
            ? 'Checklist'
            : (preview.isEmpty ? 'Note' : preview));
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drive_file_move_rounded,
                size: 18, color: theme.colorScheme.onPrimary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label.isEmpty ? 'Note' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
