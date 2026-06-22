import 'package:flutter/material.dart';

import '../../data/models/checklist_item.dart';

/// Editable checklist. Unchecked items render first (in order); checked items
/// sink below a divider. Pressing Enter on a row adds a new item; the trailing
/// "Add item" row appends one. Controllers are keyed by item id so the cursor
/// never jumps while typing.
class ChecklistBody extends StatefulWidget {
  const ChecklistBody({
    super.key,
    required this.items,
    required this.onBg,
    required this.onChanged,
    required this.newItem,
  });

  final List<ChecklistItem> items;
  final Color onBg;
  final ValueChanged<List<ChecklistItem>> onChanged;
  final ChecklistItem Function() newItem;

  @override
  State<ChecklistBody> createState() => _ChecklistBodyState();
}

class _ChecklistBodyState extends State<ChecklistBody> {
  final _controllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};

  TextEditingController _controllerFor(ChecklistItem item) {
    return _controllers.putIfAbsent(
        item.id, () => TextEditingController(text: item.text));
  }

  FocusNode _focusFor(String id) =>
      _focusNodes.putIfAbsent(id, () => FocusNode());

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _emit(List<ChecklistItem> items) {
    // Drop controllers for removed items.
    final ids = items.map((e) => e.id).toSet();
    _controllers.keys
        .where((k) => !ids.contains(k))
        .toList()
        .forEach((k) => _controllers.remove(k)?.dispose());
    widget.onChanged(items);
  }

  void _setText(String id, String text) {
    final updated = [
      for (final i in widget.items)
        if (i.id == id) i.copyWith(text: text) else i,
    ];
    _emit(updated);
  }

  void _toggle(String id, bool checked) {
    final updated = [
      for (final i in widget.items)
        if (i.id == id) i.copyWith(checked: checked) else i,
    ];
    _emit(updated);
  }

  void _remove(String id) {
    _emit(widget.items.where((i) => i.id != id).toList());
  }

  void _add({String? afterId}) {
    final item = widget.newItem();
    final list = [...widget.items];
    if (afterId == null) {
      list.add(item);
    } else {
      final idx = list.indexWhere((i) => i.id == afterId);
      list.insert(idx + 1, item);
    }
    _emit(list);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusFor(item.id).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final unchecked = widget.items.where((i) => !i.checked).toList();
    final checked = widget.items.where((i) => i.checked).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in unchecked) _row(item),
        _addRow(),
        if (checked.isNotEmpty) ...[
          const SizedBox(height: 8),
          Divider(color: widget.onBg.withValues(alpha: 0.2)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '${checked.length} checked',
              style: TextStyle(
                  color: widget.onBg.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w600),
            ),
          ),
          for (final item in checked) _row(item),
        ],
      ],
    );
  }

  Widget _row(ChecklistItem item) {
    return Padding(
      key: ValueKey(item.id),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: item.checked,
            onChanged: (v) => _toggle(item.id, v ?? false),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: TextField(
              controller: _controllerFor(item),
              focusNode: _focusFor(item.id),
              onChanged: (v) => _setText(item.id, v),
              onSubmitted: (_) => _add(afterId: item.id),
              textCapitalization: TextCapitalization.sentences,
              spellCheckConfiguration: SpellCheckConfiguration(
                misspelledTextStyle: TextField.materialMisspelledTextStyle,
              ),
              style: TextStyle(
                color: widget.onBg
                    .withValues(alpha: item.checked ? 0.5 : 0.95),
                decoration:
                    item.checked ? TextDecoration.lineThrough : null,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'List item',
                hintStyle:
                    TextStyle(color: widget.onBg.withValues(alpha: 0.4)),
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close,
                size: 18, color: widget.onBg.withValues(alpha: 0.5)),
            onPressed: () => _remove(item.id),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _addRow() {
    return InkWell(
      onTap: () => _add(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.add, color: widget.onBg.withValues(alpha: 0.6)),
            const SizedBox(width: 12),
            Text('Add item',
                style: TextStyle(color: widget.onBg.withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}
