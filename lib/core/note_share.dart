import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models/note.dart';

/// Render a note as plain text suitable for sharing or copying. Includes the
/// title (when set) and either the body or the checklist items (`☐`/`☑`).
String noteToShareText(Note note) {
  final buffer = StringBuffer();
  if (note.hasTitle) buffer.writeln(note.title!.trim());
  if (note.isChecklist) {
    for (final item in note.items) {
      final text = item.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln('${item.checked ? '☑' : '☐'} $text');
    }
  } else {
    final body = (note.body ?? '').trim();
    if (body.isNotEmpty) buffer.writeln(body);
  }
  final text = buffer.toString().trim();
  return text.isEmpty ? '(empty note)' : text;
}

/// Share a note's text via the OS share sheet. Returns false when no native
/// share is available (caller can fall back to the clipboard).
Future<bool> shareNote(Note note) async {
  final text = noteToShareText(note);
  try {
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: note.hasTitle ? note.title!.trim() : 'Note',
      ),
    );
    return true;
  } catch (_) {
    // No share target (e.g. some desktop setups) — fall back to clipboard.
    await Clipboard.setData(ClipboardData(text: text));
    return false;
  }
}
