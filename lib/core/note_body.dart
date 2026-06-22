import 'dart:convert';

import 'note_markdown.dart';

/// Extracts readable plain text from a note [body].
///
/// Note bodies are stored as a plain `String` for sync. As of the rich-text
/// editor, that string holds a Quill/Parchment **Delta JSON** document (a list
/// of insert ops). Older notes hold plain text (optionally with the brief
/// markdown-marker syntax). This returns clean reading text for previews,
/// search, share/clipboard, and notifications — without depending on the editor
/// package.
String plainTextFromBody(String? body) {
  if (body == null || body.isEmpty) return '';
  // Delta documents are a JSON array of ops; cheap prefix check before parsing.
  if (body.trimLeft().startsWith('[')) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is List) {
        final buffer = StringBuffer();
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            buffer.write(op['insert'] as String);
          }
        }
        return buffer.toString();
      }
    } catch (_) {
      // Not valid Delta JSON — fall through to legacy handling.
    }
  }
  // Legacy plain text or markdown-marker text.
  return stripMarkdown(body);
}
