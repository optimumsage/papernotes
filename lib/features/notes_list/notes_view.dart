import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';

import '../../core/note_body.dart';
import '../../core/note_sort.dart';
import '../../core/platform.dart';
import '../../core/swipe_action.dart';
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

  /// The folder label to show on [note]'s card, or null for none.
  ///
  /// Suppressed when the Notes screen is already filtered to that folder — the
  /// app bar names it there, so a chip on every card would just be noise. The
  /// mode check matters: Archive and Trash are never folder-filtered, but
  /// `selectedFolderProvider` may still hold an id from the Notes screen, so
  /// suppressing on the id alone would wrongly hide the tag in those views.
  String? _folderLabel(
      Note note, Map<String, String> names, String? selectedFolderId) {
    final folderId = note.folderId;
    if (folderId == null) return null;
    if (mode == NotesViewMode.active && selectedFolderId == folderId) {
      return null;
    }
    return names[folderId];
  }

  Widget _wrap(BuildContext context, WidgetRef ref, Note note, int previewLines,
      SwipeAction leftSwipe, SwipeAction rightSwipe,
      {required bool uniform, required String? folderName}) {
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
            uniform: uniform,
            folderName: folderName,
          ),
        ),
      ),
    );

    // Android: configurable left/right swipe actions on active notes. Mutually
    // exclusive with the desktop Draggable below (gated by platform).
    if (isAndroidPlatform &&
        mode == NotesViewMode.active &&
        (leftSwipe != SwipeAction.none || rightSwipe != SwipeAction.none)) {
      return RepaintBoundary(
        child: _swipeable(context, ref, note, card, leftSwipe, rightSwipe),
      );
    }

    if (!_desktop || mode != NotesViewMode.active) {
      return RepaintBoundary(child: card);
    }

    return RepaintBoundary(
      child: Draggable<Note>(
        data: note,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _DragFeedback(note: note),
        childWhenDragging: Opacity(opacity: 0.4, child: card),
        child: card,
      ),
    );
  }

  /// Wraps [card] in a [Dismissible] bound to the user's swipe actions.
  ///
  /// `confirmDismiss` performs the action and always returns false: the card
  /// never self-removes from the tree (which would assert before the async
  /// Drift→stream rebuild caught up). Archive/Delete remove the note naturally
  /// when the active-notes stream re-emits; Pin/Reminder/Move snap back.
  Widget _swipeable(BuildContext context, WidgetRef ref, Note note, Widget card,
      SwipeAction leftSwipe, SwipeAction rightSwipe) {
    final hasRight = rightSwipe != SwipeAction.none;
    final hasLeft = leftSwipe != SwipeAction.none;
    final DismissDirection direction = hasRight && hasLeft
        ? DismissDirection.horizontal
        : (hasRight ? DismissDirection.startToEnd : DismissDirection.endToStart);

    // A secondaryBackground requires a non-null background, so fall back to the
    // left action's background when only the left swipe is configured.
    final background = hasRight
        ? _swipeBackground(context, rightSwipe, Alignment.centerLeft)
        : (hasLeft
            ? _swipeBackground(context, leftSwipe, Alignment.centerRight)
            : null);
    final secondaryBackground = hasLeft
        ? _swipeBackground(context, leftSwipe, Alignment.centerRight)
        : null;

    return Dismissible(
      key: ValueKey('swipe-${note.id}'),
      direction: direction,
      background: background,
      secondaryBackground: secondaryBackground,
      confirmDismiss: (dir) async {
        final action =
            dir == DismissDirection.startToEnd ? rightSwipe : leftSwipe;
        await runSwipeAction(context, ref, action, note);
        return false;
      },
      child: card,
    );
  }

  Widget _swipeBackground(
      BuildContext context, SwipeAction action, Alignment alignment) {
    final scheme = Theme.of(context).colorScheme;
    final bg =
        action.isDestructive ? scheme.errorContainer : scheme.primaryContainer;
    final fg = action.isDestructive
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    return Container(
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(action.icon, color: fg),
          const SizedBox(width: 8),
          Text(action.label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewStyle =
        ref.watch(settingsControllerProvider.select((s) => s.viewStyle));
    final previewLines =
        ref.watch(settingsControllerProvider.select((s) => s.previewLines));
    final leftSwipe =
        ref.watch(settingsControllerProvider.select((s) => s.leftSwipeAction));
    final rightSwipe =
        ref.watch(settingsControllerProvider.select((s) => s.rightSwipeAction));
    final folderNames = ref.watch(folderNamesProvider);
    final selectedFolderId = ref.watch(selectedFolderProvider);

    if (viewStyle == ViewStyle.list) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
        itemCount: notes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _wrap(
            context, ref, notes[i], previewLines, leftSwipe, rightSwipe,
            uniform: true,
            folderName:
                _folderLabel(notes[i], folderNames, selectedFolderId)),
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
      itemBuilder: (context, i) => _wrap(
          context, ref, notes[i], previewLines, leftSwipe, rightSwipe,
          uniform: false,
          folderName: _folderLabel(notes[i], folderNames, selectedFolderId)),
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
    final preview = plainTextOfNote(note).trim();
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
