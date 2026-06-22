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
import 'markdown_controller.dart';
import 'ruled_lines_painter.dart';

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
  final _bodyController = MarkdownEditingController();
  final _bodyFocus = FocusNode();
  Timer? _debounce;

  /// True once the user actually changes something. Prevents merely opening a
  /// note (then leaving) from bumping its `updatedAt` / re-syncing it.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // Show the formatting toolbar only while the body is focused.
    _bodyFocus.addListener(_onBodyFocusChange);
    _init();
  }

  void _onBodyFocusChange() {
    if (mounted) setState(() {});
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
    _bodyFocus.removeListener(_onBodyFocusChange);
    _bodyFocus.dispose();
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

  // ---- rich-text formatting (lightweight markdown) ----

  /// Wraps the current selection in [marker] (e.g. `**`). With no selection,
  /// inserts an empty marker pair and parks the caret between them.
  void _wrapSelection(String marker) {
    final value = _bodyController.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final text = value.text;
    final selected = text.substring(sel.start, sel.end);
    final newText =
        text.replaceRange(sel.start, sel.end, '$marker$selected$marker');
    final newSelection = selected.isEmpty
        ? TextSelection.collapsed(offset: sel.start + marker.length)
        : TextSelection(
            baseOffset: sel.start + marker.length,
            extentOffset: sel.end + marker.length,
          );
    _bodyController.value = value.copyWith(
      text: newText,
      selection: newSelection,
      composing: TextRange.empty,
    );
    _scheduleSave();
    _bodyFocus.requestFocus();
  }

  /// Toggles a `- ` bullet prefix on the line containing the caret.
  void _toggleBulletLine() {
    final value = _bodyController.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final text = value.text;
    final lineStart = text.lastIndexOf('\n', sel.start - 1) + 1;
    final bulleted = text.startsWith('- ', lineStart);
    final String newText;
    final int delta;
    if (bulleted) {
      newText = text.replaceRange(lineStart, lineStart + 2, '');
      delta = -2;
    } else {
      newText = text.replaceRange(lineStart, lineStart, '- ');
      delta = 2;
    }
    final offset = (sel.start + delta).clamp(lineStart, newText.length);
    _bodyController.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: offset),
      composing: TextRange.empty,
    );
    _scheduleSave();
    _bodyFocus.requestFocus();
  }

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
    final ruled = ref.watch(settingsControllerProvider).ruledLines;

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
            body: Column(
              children: [
                Expanded(
                  child: ListView(
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
                        _bodyField(theme, onBg, ruled),
                      const SizedBox(height: 24),
                      _metadata(theme, onBg),
                    ],
                  ),
                ),
                // Formatting toolbar — notes only, shown while the body is focused.
                if (!_note.isChecklist && _bodyFocus.hasFocus)
                  _formattingBar(onBg, bg),
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
        spellCheckConfiguration: _spellCheck,
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

  Widget _bodyField(ThemeData theme, Color onBg, bool ruled) {
    final field = TextField(
      controller: _bodyController,
      focusNode: _bodyFocus,
      onChanged: (_) => _scheduleSave(),
      maxLines: null,
      autofocus: widget.isNew,
      textCapitalization: TextCapitalization.sentences,
      spellCheckConfiguration: _spellCheck,
      style: theme.textTheme.bodyLarge?.copyWith(color: onBg, height: 1.4),
      decoration: InputDecoration(
        hintText: 'Note',
        hintStyle: theme.textTheme.bodyLarge
            ?.copyWith(color: onBg.withValues(alpha: 0.4)),
      ),
    );
    if (!ruled) return field;

    // Ruled "paper" lines behind the text. Spacing tracks the body's rendered
    // line height (font size × line-height multiplier × the user's text scale)
    // so the lines sit under each row. The non-positioned TextField drives the
    // Stack's height, so the lines cover the full body.
    final fontSize = theme.textTheme.bodyLarge?.fontSize ?? 16;
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize) * 1.4;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: RuledLinesPainter(
              lineHeight: lineHeight,
              color: onBg.withValues(alpha: 0.12),
            ),
          ),
        ),
        field,
      ],
    );
  }

  /// Native OS spell-check (red squiggles + suggestions). Active on Android/iOS;
  /// a no-op on platforms without a default spell-check service.
  static final SpellCheckConfiguration _spellCheck = SpellCheckConfiguration(
    misspelledTextStyle: TextField.materialMisspelledTextStyle,
  );

  /// Slim formatting toolbar pinned above the keyboard.
  ///
  /// [TextFieldTapRegion] marks the bar as belonging to the body field, so
  /// tapping a button does NOT blur the field (which would hide the toolbar and
  /// cancel the press). [ExcludeFocus] additionally stops the buttons from
  /// grabbing keyboard focus. Together the field stays focused and the
  /// selection survives, so [_wrapSelection] sees the real selection.
  Widget _formattingBar(Color onBg, Color bg) {
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Material(
          color: bg,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: onBg.withValues(alpha: 0.12)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  _fmtButton(onBg, Icons.format_bold, 'Bold',
                      () => _wrapSelection('**')),
                  _fmtButton(onBg, Icons.format_italic, 'Italic',
                      () => _wrapSelection('*')),
                  _fmtButton(onBg, Icons.format_underlined, 'Underline',
                      () => _wrapSelection('_')),
                  _fmtButton(onBg, Icons.format_list_bulleted, 'Bullet',
                      _toggleBulletLine),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fmtButton(
    Color onBg,
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: onBg.withValues(alpha: 0.8)),
      onPressed: onPressed,
    );
  }
}
