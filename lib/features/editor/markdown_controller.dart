import 'package:flutter/material.dart';

import '../../core/note_markdown.dart';

/// A [TextEditingController] that renders inline markdown ([buildMarkdownSpan])
/// live while keeping the underlying value a plain `String`. Because it merely
/// subclasses the standard controller, all existing editor wiring (onChanged,
/// autosave, selection) keeps working unchanged.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Always render the styled markdown. We intentionally ignore the IME
    // composing range: on Android, Gboard keeps a composing region active on
    // the current word almost continuously, so honoring it here would suppress
    // styling nearly all the time. The styled spans preserve every character
    // (markers stay, `- ` → `•` is a 1:1 swap) so the caret/selection still map
    // 1:1 to the underlying text; only the transient composing underline is
    // dropped, which is purely cosmetic.
    final base = style ?? const TextStyle();
    final markerColor =
        (base.color ?? const Color(0xFF000000)).withValues(alpha: 0.4);
    return buildMarkdownSpan(text, base, markerColor: markerColor);
  }
}
