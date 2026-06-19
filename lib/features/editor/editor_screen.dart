import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/date_format.dart';
import '../../core/note_colors.dart';
import '../../core/note_share.dart';
import '../../data/models/checklist_item.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';
import '../reminders/reminder_sheet.dart';
import 'checklist_body.dart';
import 'color_picker.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({
    super.key,
    required this.noteId,
    required this.isNew,
    required this.type,
    this.folderId,
  });

  final String noteId;
  final bool isNew;
  final NoteType type;

  /// Folder a freshly-created note should be filed into (the folder being
  /// viewed when "+" was tapped). Null = unfiled.
  final String? folderId;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  late Note _note;
  bool _loaded = false;
  bool _showTitle = false;

  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  Timer? _debounce;

  /// True once the user actually changes something. Prevents merely opening a
  /// note (then leaving) from bumping its `updatedAt` / re-syncing it.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final repo = ref.read(noteRepositoryProvider);
    if (widget.isNew) {
      final defaultColor = ref.read(settingsControllerProvider).defaultColor;
      _note = repo.newDraft(widget.type,
          id: widget.noteId, color: defaultColor, folderId: widget.folderId);
      // Checklist titles are required, so the field is shown from the start.
      _showTitle = widget.type == NoteType.checklist;
    } else {
      final existing = await repo.getNote(widget.noteId);
      if (existing == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      _note = existing;
      _showTitle = _note.hasTitle || _note.isChecklist;
    }
    _titleController.text = _note.title ?? '';
    _bodyController.text = _note.body ?? '';
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  // ---- persistence ----

  void _scheduleSave() {
    _dirty = true;
    _note = _note.copyWith(
      title: _titleController.text,
      body: _bodyController.text,
    );
    _debounce?.cancel();
    _debounce = Timer(AppConfig.autosaveDebounce, _flush);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    _note = _note.copyWith(
      title: _titleController.text,
      body: _bodyController.text,
    );
    if (_shouldDiscard) return; // don't persist invalid/empty drafts
    if (!_dirty) return; // nothing changed — don't bump updatedAt
    await ref.read(noteRepositoryProvider).save(_note);
  }

  /// A new note with no content, or any checklist left without its required
  /// title, should not be persisted.
  bool get _shouldDiscard {
    if (_note.isEmpty) return true;
    if (_note.isChecklist && !_note.hasTitle) return true;
    return false;
  }

  Future<void> _onExit() async {
    _debounce?.cancel();
    _note = _note.copyWith(
      title: _titleController.text,
      body: _bodyController.text,
    );
    if (_shouldDiscard) {
      await ref.read(noteRepositoryProvider).discardDraft(_note.id);
    } else if (_dirty) {
      await ref.read(noteRepositoryProvider).save(_note);
    }
  }

  // ---- checklist mutations ----

  void _updateItems(List<ChecklistItem> items) {
    setState(() => _note = _note.copyWith(items: items));
    _scheduleSave();
  }

  ChecklistItem _newItem() => ref.read(noteRepositoryProvider).newItem();

  // ---- menu actions ----

  /// Move the note to Trash (recoverable) and leave the editor.
  Future<void> _delete() async {
    _debounce?.cancel();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(noteRepositoryProvider);
    if (!widget.isNew) {
      await repo.moveToTrash(_note.id);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: const Text('Moved to Trash'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
            label: 'Undo', onPressed: () => repo.restore(_note.id)),
      ));
    }
    nav.pop();
  }

  /// Archive the note and leave the editor.
  Future<void> _archive() async {
    _debounce?.cancel();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(noteRepositoryProvider);
    // Persist current edits before archiving so nothing is lost.
    await _flush();
    if (!_shouldDiscard) {
      await repo.archive(_note.id);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: const Text('Archived'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
            label: 'Undo', onPressed: () => repo.unarchive(_note.id)),
      ));
    }
    nav.pop();
  }

  void _pickColor() {
    ColorPickerSheet.show(
      context,
      selected: _note.color,
      onPick: (c) {
        setState(() => _note = _note.copyWith(color: c));
        _scheduleSave();
      },
    );
  }

  void _togglePin() {
    setState(() => _note = _note.copyWith(pinned: !_note.pinned));
    _scheduleSave();
  }

  /// Persist current edits, then open the reminder sheet so the row exists for
  /// [NoteRepository.setReminder] to update.
  Future<void> _openReminder() async {
    await _flush();
    if (_shouldDiscard || !mounted) return;
    await ReminderSheet.show(context, ref, _note);
  }

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    final shared = await shareNote(_note);
    if (!shared) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
          const SnackBar(content: Text('Copied to clipboard')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final theme = Theme.of(context);
    final bg = NoteColors.background(_note.color, theme.brightness);
    final onBg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : const Color(0xFF1E1E22);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        await _onExit();
        nav.pop();
      },
      child: Hero(
        tag: 'note-${_note.id}',
        child: Material(
          color: bg,
          child: Scaffold(
            backgroundColor: bg,
            appBar: AppBar(
              backgroundColor: bg,
              foregroundColor: onBg,
              leading: BackButton(
                color: onBg,
                onPressed: () async {
                  final nav = Navigator.of(context);
                  await _onExit();
                  nav.pop();
                },
              ),
              actions: [
                IconButton(
                  tooltip: _note.pinned ? 'Unpin' : 'Pin',
                  icon: Icon(
                    _note.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                    color: onBg,
                  ),
                  onPressed: _togglePin,
                ),
                IconButton(
                  tooltip: 'Color',
                  icon: Icon(Icons.palette_outlined, color: onBg),
                  onPressed: _pickColor,
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: onBg),
                  onSelected: (value) {
                    switch (value) {
                      case 'add_title':
                        setState(() => _showTitle = true);
                      case 'reminder':
                        _openReminder();
                      case 'share':
                        _share();
                      case 'archive':
                        _archive();
                      case 'delete':
                        _delete();
                    }
                  },
                  itemBuilder: (context) => [
                    if (!_showTitle)
                      const PopupMenuItem(
                        value: 'add_title',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.title),
                          title: Text('Add title'),
                        ),
                      ),
                    // Reminders only fire for active notes.
                    if (!_note.isArchived)
                      PopupMenuItem(
                        value: 'reminder',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(_note.hasReminder
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_outlined),
                          title: Text(_note.hasReminder
                              ? 'Edit reminder…'
                              : 'Reminder…'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.share_outlined),
                        title: Text('Share'),
                      ),
                    ),
                    if (!widget.isNew)
                      const PopupMenuItem(
                        value: 'archive',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.archive_outlined),
                          title: Text('Archive'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                if (_showTitle) _titleField(theme, onBg),
                if (_note.isChecklist)
                  ChecklistBody(
                    items: _note.items,
                    onBg: onBg,
                    onChanged: _updateItems,
                    newItem: _newItem,
                  )
                else
                  _bodyField(theme, onBg),
                const SizedBox(height: 24),
                _metadata(theme, onBg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Small muted footer showing when the note was created and last edited.
  Widget _metadata(ThemeData theme, Color onBg) {
    return Text(
      'Created ${fullDate(_note.createdAt)} · Edited ${relativeTime(_note.updatedAt)}',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: onBg.withValues(alpha: 0.5)),
    );
  }

  Widget _titleField(ThemeData theme, Color onBg) {
    final required = _note.isChecklist && !_note.hasTitle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _titleController,
        onChanged: (_) => _scheduleSave(),
        textCapitalization: TextCapitalization.sentences,
        style: theme.textTheme.headlineSmall
            ?.copyWith(color: onBg, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          hintText: _note.isChecklist ? 'Title (required)' : 'Title',
          hintStyle: theme.textTheme.headlineSmall?.copyWith(
            color: required
                ? theme.colorScheme.error.withValues(alpha: 0.8)
                : onBg.withValues(alpha: 0.4),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _bodyField(ThemeData theme, Color onBg) {
    return TextField(
      controller: _bodyController,
      onChanged: (_) => _scheduleSave(),
      maxLines: null,
      autofocus: widget.isNew,
      textCapitalization: TextCapitalization.sentences,
      style: theme.textTheme.bodyLarge?.copyWith(color: onBg, height: 1.4),
      decoration: InputDecoration(
        hintText: 'Note',
        hintStyle: theme.textTheme.bodyLarge
            ?.copyWith(color: onBg.withValues(alpha: 0.4)),
      ),
    );
  }
}
