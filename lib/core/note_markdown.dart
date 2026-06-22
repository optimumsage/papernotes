/// Legacy markdown-marker cleanup.
///
/// A short-lived release stored note bodies as plain text with inline markdown
/// markers (`**bold**`, `*italic*`, `_underline_`, `- ` bullets). The rich-text
/// editor replaced that with a Delta document, but old/synced notes may still
/// carry the marker syntax. [stripMarkdown] removes the inline markers and
/// normalizes bullet prefixes to `• ` so such text reads cleanly when shown
/// read-only or migrated into the editor.
String stripMarkdown(String text) {
  final lines = text.split('\n').map((line) {
    if (line.startsWith('- ')) return '• ${line.substring(2)}';
    return line;
  }).join('\n');
  return lines
      .replaceAllMapped(RegExp(r'\*\*([^*\n]+)\*\*'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'\*([^*\n]+)\*'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'_([^_\n]+)_'), (m) => m[1]!);
}
