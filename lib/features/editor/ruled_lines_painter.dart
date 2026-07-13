import 'package:flutter/material.dart';

/// Paints faint horizontal "paper" lines behind the note body. Lines are spaced
/// at [lineHeight] (the body text's rendered line height) so they sit under each
/// row of text, and fill the whole paint area (the editor viewport) — not just
/// where text exists.
///
/// When [scroll] is supplied, the line grid is offset by the editor's scroll
/// position so the rules scroll with the text (the editor owns the scroll), and
/// the painter repaints as the offset changes.
class RuledLinesPainter extends CustomPainter {
  RuledLinesPainter({
    required this.lineHeight,
    required this.color,
    this.scroll,
    this.topPadding = 0,
  }) : super(repaint: scroll);

  /// Vertical spacing between lines — should match the text line height.
  final double lineHeight;
  final Color color;

  /// The editor's scroll controller. When attached, the grid slides with the
  /// content so the rules stay aligned to each text row while scrolling.
  final ScrollController? scroll;

  /// Offset of the first line from the top of the paint area.
  final double topPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineHeight <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final offset =
        (scroll != null && scroll!.hasClients) ? scroll!.offset : 0.0;
    // A continuous grid of rules at content positions `topPadding + k*lineHeight`
    // (k = 0,1,2,…), shifted up by the scroll offset so the lines track the text
    // and fill the whole viewport. `phase` is the first grid line at or below 0.
    var phase = (topPadding - offset) % lineHeight;
    if (phase < 0) phase += lineHeight;
    // The +0.5 tolerance ensures the last rule still draws when the height is an
    // exact multiple of [lineHeight].
    for (var y = phase; y <= size.height + 0.5; y += lineHeight) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(RuledLinesPainter old) =>
      old.lineHeight != lineHeight ||
      old.color != color ||
      old.scroll != scroll ||
      old.topPadding != topPadding;
}
