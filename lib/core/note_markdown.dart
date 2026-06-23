/// Legacy markdown-marker cleanup.
///
/// A short-lived release stored note bodies as plain text with inline markdown
/// markers (`**bold**`, `*italic*`, `_underline_`, `- ` bullets). The rich-text
/// editor replaced that with a Delta document, but old/synced notes may still
/// carry the marker syntax. [stripMarkdown] removes the inline markers and
/// normalizes bullet prefixes to `• ` so such text reads cleanly when shown
/// read-only or migrated into the editor.
// Compiled once at load — these are hot (called per legacy note body during
// previews/search and when migrating a note into the editor).
final _boldMarker = RegExp(r'\*\*([^*\n]+)\*\*');
final _italicMarker = RegExp(r'\*([^*\n]+)\*');
final _underlineMarker = RegExp(r'_([^_\n]+)_');

String stripMarkdown(String text) {
  final lines = text.split('\n').map((line) {
    if (line.startsWith('- ')) return '• ${line.substring(2)}';
    return line;
  }).join('\n');
  return lines
      .replaceAllMapped(_boldMarker, (m) => m[1]!)
      .replaceAllMapped(_italicMarker, (m) => m[1]!)
      .replaceAllMapped(_underlineMarker, (m) => m[1]!);
}
