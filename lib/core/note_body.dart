import 'dart:convert';

import 'note_markdown.dart';

/// Bounded memo cache keyed by the raw body string. Extraction is pure over its
/// input and bodies are immutable, so the same string always maps to the same
/// plain text. This is hot — invoked per card build and per note on every search
/// keystroke — and decoding a Delta document each time dominates list/search
/// cost. Cap the size and evict in insertion order (oldest first) so memory
/// stays bounded even with many distinct notes.
const _maxCacheEntries = 512;
final Map<String, String> _plainTextCache = <String, String>{};

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
  final cached = _plainTextCache[body];
  if (cached != null) return cached;
  final result = _extractPlainText(body);
  if (_plainTextCache.length >= _maxCacheEntries) {
    _plainTextCache.remove(_plainTextCache.keys.first);
  }
  _plainTextCache[body] = result;
  return result;
}

String _extractPlainText(String body) {
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
