import 'package:flutter/material.dart';

/// Paints faint horizontal "paper" lines behind the note body. Lines are spaced
/// at [lineHeight] (the body text's rendered line height) so they sit under each
/// row of text.
class RuledLinesPainter extends CustomPainter {
  RuledLinesPainter({
    required this.lineHeight,
    required this.color,
    this.topPadding = 0,
  });

  /// Vertical spacing between lines — should match the text line height.
  final double lineHeight;
  final Color color;

  /// Offset of the first line from the top of the paint area.
  final double topPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineHeight <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    // The +0.5 tolerance ensures the rule under the final line still draws when
    // the content height is an exact multiple of [lineHeight] (floating-point
    // equality would otherwise drop it).
    var y = topPadding + lineHeight;
    while (y <= size.height + 0.5) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += lineHeight;
    }
  }

  @override
  bool shouldRepaint(RuledLinesPainter old) =>
      old.lineHeight != lineHeight ||
      old.color != color ||
      old.topPadding != topPadding;
}
