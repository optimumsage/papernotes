import 'package:flutter/material.dart';

import '../../core/date_format.dart';
import '../../core/note_body.dart';
import '../../core/note_colors.dart';
import '../../data/models/note.dart';

/// A single Keep-style card in the notes grid. Shows the title only when set,
/// a short preview of the body or checklist, and the note's color.
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.maxPreviewLines = 8,
  });

  final Note note;
  final VoidCallback onTap;

  /// How many lines of the body/checklist preview to show (user setting, 1..8).
  final int maxPreviewLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = NoteColors.background(note.color, theme.brightness);
    final onBg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : const Color(0xFF1E1E22);

    return Card(
      color: bg,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note.pinned || note.hasReminder)
                Align(
                  alignment: Alignment.topRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (note.hasReminder)
                        Icon(
                          note.reminderType == ReminderType.pinned
                              ? Icons.push_pin_outlined
                              : Icons.alarm,
                          size: 14,
                          color: onBg.withValues(alpha: 0.5),
                        ),
                      if (note.pinned) ...[
                        if (note.hasReminder) const SizedBox(width: 4),
                        Icon(Icons.push_pin,
                            size: 14, color: onBg.withValues(alpha: 0.5)),
                      ],
                    ],
                  ),
                ),
              if (note.hasTitle) ...[
                Text(
                  note.title!.trim(),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: onBg, fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
              ],
              _preview(context, onBg),
              const SizedBox(height: 8),
              Text(
                'Edited ${relativeTime(note.updatedAt)}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: onBg.withValues(alpha: 0.55)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, Color onBg) {
    final theme = Theme.of(context);
    if (note.isChecklist) {
      final shown = note.items.take(maxPreviewLines).toList();
      final remaining = note.items.length - shown.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    item.checked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: onBg.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.text.isEmpty ? ' ' : item.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: onBg.withValues(alpha: item.checked ? 0.5 : 0.9),
                        decoration:
                            item.checked ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (remaining > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('+$remaining more',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: onBg.withValues(alpha: 0.6))),
            ),
        ],
      );
    }

    final body = plainTextFromBody(note.body).trim();
    if (body.isEmpty && !note.hasTitle) {
      return Text('Empty note',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: onBg.withValues(alpha: 0.5)));
    }
    if (body.isEmpty) return const SizedBox.shrink();
    return Text(
      body,
      maxLines: maxPreviewLines,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium
          ?.copyWith(color: onBg.withValues(alpha: 0.9), height: 1.35),
    );
  }
}
