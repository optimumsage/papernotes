import 'package:flutter/material.dart';

/// Lightweight inline-markdown support for note bodies.
///
/// Notes stay plain `String`s (so storage and Drive sync are unchanged); the
/// editor renders a small set of markers live and the toolbar inserts them:
///   - `**bold**`
///   - `*italic*`
///   - `_underline_`
///   - lines starting with `- ` (or `• `) become bullets
///
/// Flutter requires the rendered character count to match the controller text,
/// so markers stay visible while editing (just dimmed). Read-only surfaces
/// (card previews, share text) use [stripMarkdown] for a clean read.

/// A single run of tokenized inline markdown. A run is either a [marker]
/// (the `*`/`_` characters themselves) or styled/plain content.
class MdToken {
  const MdToken(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.marker = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool marker;
}

// Bold must be tried before italic so `**` wins over `*`.
final RegExp _inlinePattern =
    RegExp(r'\*\*([^*\n]+)\*\*|\*([^*\n]+)\*|_([^_\n]+)_');

/// Splits [text] into inline runs, preserving every character (markers are kept
/// as their own tokens). Bullet prefixes are line-level and handled separately
/// by [buildMarkdownSpan], so this operates purely on inline emphasis.
List<MdToken> tokenizeMarkdown(String text) {
  final tokens = <MdToken>[];
  var index = 0;
  for (final m in _inlinePattern.allMatches(text)) {
    if (m.start > index) {
      tokens.add(MdToken(text.substring(index, m.start)));
    }
    if (m.group(1) != null) {
      tokens
        ..add(const MdToken('**', marker: true))
        ..add(MdToken(m.group(1)!, bold: true))
        ..add(const MdToken('**', marker: true));
    } else if (m.group(2) != null) {
      tokens
        ..add(const MdToken('*', marker: true))
        ..add(MdToken(m.group(2)!, italic: true))
        ..add(const MdToken('*', marker: true));
    } else {
      tokens
        ..add(const MdToken('_', marker: true))
        ..add(MdToken(m.group(3)!, underline: true))
        ..add(const MdToken('_', marker: true));
    }
    index = m.end;
  }
  if (index < text.length) tokens.add(MdToken(text.substring(index)));
  return tokens;
}

/// Builds a styled [TextSpan] for [text]. Marker characters are tinted with
/// [markerColor]; a leading `- ` / `• ` on a line is rendered as a `•` bullet
/// (a 1:1 glyph swap, so the character count is unchanged).
TextSpan buildMarkdownSpan(
  String text,
  TextStyle base, {
  required Color markerColor,
}) {
  final children = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    _appendLine(children, lines[i], base, markerColor);
    if (i != lines.length - 1) children.add(const TextSpan(text: '\n'));
  }
  return TextSpan(style: base, children: children);
}

void _appendLine(
  List<InlineSpan> out,
  String line,
  TextStyle base,
  Color markerColor,
) {
  var content = line;
  if (line.startsWith('- ') || line.startsWith('• ')) {
    // Replace the single leading marker char with a bullet glyph (same length).
    out.add(TextSpan(
        text: '•', style: base.copyWith(fontWeight: FontWeight.w600)));
    content = line.substring(1);
  }
  for (final t in tokenizeMarkdown(content)) {
    if (t.marker) {
      out.add(TextSpan(text: t.text, style: base.copyWith(color: markerColor)));
    } else {
      out.add(TextSpan(
        text: t.text,
        style: base.copyWith(
          fontWeight: t.bold ? FontWeight.w700 : null,
          fontStyle: t.italic ? FontStyle.italic : null,
          decoration: t.underline ? TextDecoration.underline : null,
        ),
      ));
    }
  }
}

/// Removes inline markdown markers and normalizes bullet prefixes to `• `, for
/// read-only surfaces (card previews, share/clipboard text).
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
