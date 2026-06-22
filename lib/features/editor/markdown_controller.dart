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
    // While the IME is actively composing (e.g. autocorrect / CJK input), defer
    // to the default rendering so the composing underline isn't disturbed.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final base = style ?? const TextStyle();
    final markerColor =
        (base.color ?? const Color(0xFF000000)).withValues(alpha: 0.35);
    return buildMarkdownSpan(text, base, markerColor: markerColor);
  }
}
