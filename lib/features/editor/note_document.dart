import 'dart:convert';

import 'package:fleather/fleather.dart';

import '../../core/note_markdown.dart';

/// Converts a stored note [body] into a [ParchmentDocument] for the editor.
///
/// New notes store a Parchment/Quill **Delta JSON** document. Legacy notes hold
/// plain text (or the short-lived markdown-marker syntax); those are migrated to
/// a plain-paragraph document on open (markers stripped). Anything that fails to
/// parse falls back to plain text so a note can never fail to open.
ParchmentDocument documentFromBody(String? body) {
  if (body == null || body.trim().isEmpty) return ParchmentDocument();
  if (body.trimLeft().startsWith('[')) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is List) return ParchmentDocument.fromJson(decoded);
    } catch (_) {
      // Not valid Delta — treat as legacy text below.
    }
  }
  return ParchmentDocument.fromDelta(_plainTextDelta(stripMarkdown(body)));
}

/// Serializes the editor [doc] back to the stored `body` string. Returns an
/// empty string for an effectively-empty document so the editor's
/// discard-empty-note logic (which checks `body.trim().isEmpty`) still works.
String? bodyFromDocument(ParchmentDocument doc) {
  if (doc.toPlainText().trim().isEmpty) return '';
  return jsonEncode(doc.toDelta().toJson());
}

Delta _plainTextDelta(String text) {
  // A Parchment document must end in a newline.
  final normalized = text.endsWith('\n') ? text : '$text\n';
  return Delta()..insert(normalized);
}
