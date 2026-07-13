import 'dart:async';

import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_snackbar.dart';
import '../../core/constants.dart';
import '../../core/date_format.dart';
import '../../core/note_colors.dart';
import '../../core/note_share.dart';
import '../../data/models/attachment.dart';
import '../../data/models/checklist_item.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';
import '../reminders/reminder_sheet.dart';
import 'attachment_picker.dart';
import 'attachment_section.dart';
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
  StreamSubscription? _docChanges;
  Timer? _debounce;

  /// True once the user actually changes something. Prevents merely opening a
  /// note (then leaving) from bumping its `updatedAt` / re-syncing it.
  bool _dirty = false;

  /// Title/body as last loaded or saved. Compared at flush time so
  /// serialization-neutral edits (whitespace in an empty body, undo back to
  /// the saved state) don't bump `updatedAt` or trigger a sync push.
  String _savedBody = '';
  String _savedTitle = '';

  /// True when a non-text field changed (color, pin, checklist items,
  /// attachments) — those aren't visible in the title/body comparison.
  bool _metaDirty = false;

  /// True while the body holds a non-collapsed (range) selection. On touch
  /// platforms the outer scroll's physics are locked while this is true so a
  /// selection handle can be dragged vertically without the scroll view
  /// stealing the gesture — without this, Android can't extend/adjust a
  /// selection because the vertical drag is claimed by the page scroll.
  bool _hasRangeSelection = false;

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
    _savedTitle = _titleController.text;
    final controller = FleatherController(document: documentFromBody(_note.body));
    _savedBody = bodyFromDocument(controller.document) ?? '';
    // Content mutations only (selection moves don't emit here), so merely
    // moving the caret never marks the note dirty. Serialization is deferred
    // to the debounced flush — nothing walks the document per keystroke.
    _docChanges = controller.document.changes.listen((_) => _scheduleSave());
    // Selection changes (unlike document changes) come through the controller
    // itself; used to lock the outer scroll while a range selection is active.
    controller.addListener(_onSelectionChanged);
    _body = controller;
    setState(() => _loaded = true);
  }

  void _onSelectionChanged() {
    final has = !_body!.selection.isCollapsed;
    if (has != _hasRangeSelection && mounted) {
      setState(() => _hasRangeSelection = has);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _docChanges?.cancel();
    _bodyFocus.removeListener(_onBodyFocusChange);
    _bodyFocus.dispose();
    _titleController.dispose();
    _body?.removeListener(_onSelectionChanged);
    _body?.dispose();
    super.dispose();
  }

  // ---- persistence ----

  String _currentBody() => bodyFromDocument(_body!.document) ?? '';

  /// Marks the note dirty and (re)arms the autosave debounce. Title and body
  /// are only serialized into [_note] at flush/exit time — nothing walks the
  /// document per keystroke.
  void _scheduleSave() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(AppConfig.autosaveDebounce, _flush);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    final title = _titleController.text;
    final body = _currentBody();
    _note = _note.copyWith(title: title, body: body);
    if (_shouldDiscard) return; // don't persist invalid/empty drafts
    if (!_dirty) return; // nothing changed — don't bump updatedAt
    // Edits that serialize back to the saved state are no-ops.
    if (!_metaDirty && body == _savedBody && title == _savedTitle) return;
    await ref.read(noteRepositoryProvider).save(_note);
    _savedBody = body;
    _savedTitle = title;
    _metaDirty = false;
    _dirty = false;
  }

  /// A new note with no content, or any checklist left without its required
  /// title, should not be persisted. An attachment always counts as content:
  /// discarding would silently delete the just-imported file.
  bool get _shouldDiscard {
    if (_note.hasAttachments) return false;
    if (_note.isEmpty) return true;
    if (_note.isChecklist && !_note.hasTitle) return true;
    return false;
  }

  Future<void> _onExit() async {
    await _flush();
    if (_shouldDiscard) {
      await ref.read(noteRepositoryProvider).discardDraft(_note.id);
    }
  }

  // ---- checklist mutations ----

  void _updateItems(List<ChecklistItem> items) {
    setState(() => _note = _note.copyWith(items: items));
    _metaDirty = true;
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
        _metaDirty = true;
        _scheduleSave();
      },
    );
  }

  void _togglePin() {
    setState(() => _note = _note.copyWith(pinned: !_note.pinned));
    _metaDirty = true;
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
    // Fold in unflushed edits so Share exports what's on screen, not the
    // last-autosaved state.
    _note = _note.copyWith(title: _titleController.text, body: _currentBody());
    final shared = await shareNote(_note);
    if (!shared) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
          const SnackBar(content: Text('Copied to clipboard')));
    }
  }

  // ---- attachments ----

  /// Pick (file / scan / camera per platform), import into the attachment
  /// store, and persist immediately — the binary is already on disk, so the
  /// metadata must not sit in the debounce window.
  Future<void> _addAttachment() async {
    final store = ref.read(attachmentStoreProvider);
    try {
      final added = await pickAttachments(context, store, _note.id);
      if (added.isEmpty) return;
      if (!mounted) {
        // Editor is gone — remove the just-imported copies rather than
        // leaving orphaned files under a live note id.
        for (final attachment in added) {
          unawaited(store.remove(_note.id, attachment));
        }
        return;
      }
      setState(() => _note =
          _note.copyWith(attachments: [..._note.attachments, ...added]));
      _dirty = true;
      _metaDirty = true;
      await _flush();
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Could not attach file: $e');
    }
  }

  /// Confirm, then drop the attachment from the note and delete its file
  /// (there is no undo — the binary is gone).
  Future<void> _removeAttachment(NoteAttachment attachment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove attachment?'),
        content: Text('"${attachment.name}" will be deleted from this note.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _note = _note.copyWith(
        attachments:
            _note.attachments.where((a) => a.id != attachment.id).toList()));
    _dirty = true;
    _metaDirty = true;
    await _flush();
    await ref.read(attachmentStoreProvider).remove(_note.id, attachment);
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
    // select() so unrelated settings changes (e.g. the post-sync lastSyncedAt
    // refresh that lands seconds after every autosave) don't rebuild the editor.
    final ruled =
        ref.watch(settingsControllerProvider.select((s) => s.ruledLines));

    // Touch platforms only: freeze the page scroll while a range selection is
    // active so selection handles can be dragged (see [_hasRangeSelection]).
    // Never lock on desktop — NeverScrollableScrollPhysics also kills the
    // mouse wheel.
    final lockScroll = _hasRangeSelection &&
        (theme.platform == TargetPlatform.android ||
            theme.platform == TargetPlatform.iOS);

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
                  tooltip: 'Attach',
                  icon: Icon(Icons.attach_file, color: onBg),
                  onPressed: _addAttachment,
                ),
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
                  // LayoutBuilder wraps the scroll (not a child of it) so it can
                  // read the viewport height; a builder inside a scroll sees an
                  // unbounded main axis.
                  child: LayoutBuilder(
                    builder: (context, viewport) {
                      const pad = EdgeInsets.fromLTRB(20, 8, 20, 40);
                      // Make the content fill at least the viewport so the ruled
                      // "paper" lines cover the whole page even for a short note.
                      // The note body (in Expanded below) absorbs the slack;
                      // longer notes grow past this via IntrinsicHeight and the
                      // scroll view scrolls the whole column (lines scroll with
                      // the text — no drift).
                      final minBody = viewport.maxHeight - pad.vertical;
                      return SingleChildScrollView(
                        physics: lockScroll
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        padding: pad,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: minBody),
                          // IntrinsicHeight lets the body Expanded resolve to the
                          // real content height when it exceeds minBody. Valid
                          // here because Fleather's editable box implements
                          // intrinsic height; the double-layout cost is
                          // negligible for note-sized documents.
                          child: IntrinsicHeight(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                  // Only the body absorbs the extra height so the
                                  // ruled grid fills down to the page bottom.
                                  Expanded(
                                      child: _bodyField(theme, onBg, ruled)),
                                if (_note.hasAttachments) ...[
                                  const SizedBox(height: 24),
                                  AttachmentSection(
                                    noteId: _note.id,
                                    attachments: _note.attachments,
                                    store: ref.read(attachmentStoreProvider),
                                    onBg: onBg,
                                    onRemove: _removeAttachment,
                                  ),
                                ],
                                const SizedBox(height: 24),
                                _metadata(theme, onBg),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
          // An empty Parchment document is a single '\n' (length 1) — checking
          // the length avoids materializing the full plain text per keystroke.
          if (_body!.document.length > 1) {
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

    // Ruled "paper" lines behind the text. Spacing must equal the editor's
    // *actual* rendered line height, which is not simply font size × height —
    // the font's metrics and rounding make it differ (e.g. 22.0, not 16×1.4 =
    // 22.4). Measuring it the way Fleather lays out a line keeps the rules on
    // the exact grid the text uses, so they never drift across many lines.
    // The non-positioned editor drives the Stack's height, so lines fill it.
    final lineHeight = _measuredLineHeight(context, baseStyle);
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

  /// The exact rendered height of one body line, measured the way Fleather lays
  /// out a paragraph: a strut with `forceStrutHeight` plus the ambient text
  /// scaler (see text_line.dart in the fleather package). Computing this rather
  /// than `fontSize × height` is what keeps the ruled lines from drifting — the
  /// naive product overestimates the real metric by a fraction of a pixel per
  /// line, which accumulates into visible overlap further down the page.
  double _measuredLineHeight(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
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
