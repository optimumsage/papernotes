import 'dart:async';

import 'package:fleather/fleather.dart';
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
import 'note_document.dart';
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
  /// Line-height multiplier for the note body. Shared by the body text style
  /// and the ruled-line painter so the rules stay aligned with each text row.
  static const _bodyLineHeightFactor = 1.4;

  late Note _note;
  bool _loaded = false;
  bool _showTitle = false;

  final _titleController = TextEditingController();
  final _bodyFocus = FocusNode();
  FleatherController? _body;
  Timer? _debounce;

  /// Serialized document as last loaded/saved. Lets us tell a real content edit
  /// (mark dirty) from a selection-only change (ignore), so merely moving the
  /// caret never bumps `updatedAt`.
  String _savedBody = '';

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
    final controller = FleatherController(document: documentFromBody(_note.body));
    _savedBody = bodyFromDocument(controller.document) ?? '';
    controller.addListener(_onBodyChanged);
    _body = controller;
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _bodyFocus.removeListener(_onBodyFocusChange);
    _bodyFocus.dispose();
    _titleController.dispose();
    _body?.removeListener(_onBodyChanged);
    _body?.dispose();
    super.dispose();
  }

  // ---- persistence ----

  String _currentBody() => bodyFromDocument(_body!.document) ?? '';

  /// Fires on every document change (content or selection). Selection-only
  /// changes serialize identically, so they don't mark the note dirty.
  void _onBodyChanged() {
    final body = _currentBody();
    if (body == _savedBody) return;
    _dirty = true;
    _note = _note.copyWith(title: _titleController.text, body: body);
    _debounce?.cancel();
    _debounce = Timer(AppConfig.autosaveDebounce, _flush);
  }

  void _scheduleSave() {
    _dirty = true;
    _note = _note.copyWith(
      title: _titleController.text,
      body: _currentBody(),
    );
    _debounce?.cancel();
    _debounce = Timer(AppConfig.autosaveDebounce, _flush);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    _note = _note.copyWith(
      title: _titleController.text,
      body: _currentBody(),
    );
    if (_shouldDiscard) return; // don't persist invalid/empty drafts
    if (!_dirty) return; // nothing changed — don't bump updatedAt
    await ref.read(noteRepositoryProvider).save(_note);
    _savedBody = _note.body ?? '';
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
      body: _currentBody(),
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

  // ---- rich-text formatting ----

  bool _hasAttr(ParchmentAttribute attr) =>
      _body!.getSelectionStyle().containsSame(attr);

  /// Toggles an inline/block attribute on the current selection (or, when the
  /// selection is collapsed, on the text typed next).
  void _toggleAttr(ParchmentAttribute attr) {
    _body!.formatSelection(_hasAttr(attr) ? attr.unset : attr);
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
    final baseStyle = theme.textTheme.bodyLarge!
        .copyWith(color: onBg, height: _bodyLineHeightFactor);

    // DefaultTextStyle drives FleatherEditor's base paragraph style (it derives
    // its theme from the ambient text style), so this sets the body font/colour.
    final fleatherEditor = FleatherEditor(
      controller: _body!,
      focusNode: _bodyFocus,
      scrollable: false,
      autofocus: widget.isNew,
      padding: EdgeInsets.zero,
      spellCheckConfiguration: _spellCheck,
    );

    // On ruled paper the text must sit on a uniform line grid. Fleather's
    // fallback theme otherwise forces paragraph line-height to 1.3 (not our
    // 1.4) and wraps every paragraph in VerticalSpacing(top: 6, bottom: 10) —
    // so text starts 6px low and each paragraph break drifts ~16px off the
    // grid, overlapping the rules. Override the paragraph block to use our line
    // height with no extra spacing so paragraphs land exactly on the grid the
    // painter draws. (Plain notes keep Fleather's default comfortable spacing.)
    final Widget body = ruled
        ? Builder(
            builder: (context) {
              final base = FleatherThemeData.fallback(context);
              return FleatherTheme(
                data: base.copyWith(
                  paragraph: TextBlockTheme(
                    style: baseStyle,
                    spacing: const VerticalSpacing.zero(),
                  ),
                ),
                child: fleatherEditor,
              );
            },
          )
        : fleatherEditor;

    final editor = DefaultTextStyle(style: baseStyle, child: body);

    // "Note" placeholder, shown only while the document is empty.
    final hint = Positioned(
      left: 0,
      top: 0,
      child: ListenableBuilder(
        listenable: _body!,
        builder: (context, _) {
          if (_body!.document.toPlainText().trim().isNotEmpty) {
            return const SizedBox.shrink();
          }
          return IgnorePointer(
            child: Text('Note',
                style: baseStyle.copyWith(color: onBg.withValues(alpha: 0.4))),
          );
        },
      ),
    );

    final stacked = Stack(children: [editor, hint]);
    if (!ruled) return stacked;

    // Ruled "paper" lines behind the text. Spacing tracks the body's rendered
    // line height (font size × line-height multiplier × the user's text scale).
    // The non-positioned editor drives the Stack's height, so lines fill it.
    final fontSize = theme.textTheme.bodyLarge?.fontSize ?? 16;
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize) *
        _bodyLineHeightFactor;
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
        stacked,
      ],
    );
  }

  /// Native OS spell-check (red squiggles + suggestions), enabled only where the
  /// platform actually provides a spell-check service (Android/iOS). On desktop
  /// there is no service, so we pass null (disabled) rather than trip
  /// EditableText's "no spell check service" error.
  SpellCheckConfiguration? get _spellCheck =>
      WidgetsBinding.instance.platformDispatcher.nativeSpellCheckServiceDefined
          ? SpellCheckConfiguration(
              misspelledTextStyle: TextField.materialMisspelledTextStyle,
            )
          : null;

  /// Slim formatting toolbar pinned above the keyboard.
  ///
  /// [TextFieldTapRegion] marks the bar as belonging to the body field, so
  /// tapping a button does NOT blur the editor. [ExcludeFocus] additionally
  /// stops the buttons from grabbing keyboard focus. The [ListenableBuilder]
  /// rebuilds the button states so active formatting is highlighted as the
  /// selection moves.
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
              child: ListenableBuilder(
                listenable: _body!,
                builder: (context, _) => Row(
                  children: [
                    _fmtButton(onBg, Icons.format_bold, 'Bold',
                        _hasAttr(ParchmentAttribute.bold),
                        () => _toggleAttr(ParchmentAttribute.bold)),
                    _fmtButton(onBg, Icons.format_italic, 'Italic',
                        _hasAttr(ParchmentAttribute.italic),
                        () => _toggleAttr(ParchmentAttribute.italic)),
                    _fmtButton(onBg, Icons.format_underlined, 'Underline',
                        _hasAttr(ParchmentAttribute.underline),
                        () => _toggleAttr(ParchmentAttribute.underline)),
                    _fmtButton(onBg, Icons.format_list_bulleted, 'Bullet',
                        _hasAttr(ParchmentAttribute.ul),
                        () => _toggleAttr(ParchmentAttribute.ul)),
                  ],
                ),
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
    bool active,
    VoidCallback onPressed,
  ) {
    return IconButton(
      tooltip: tooltip,
      isSelected: active,
      icon: Icon(icon,
          color: active ? onBg : onBg.withValues(alpha: 0.6)),
      onPressed: onPressed,
    );
  }
}
