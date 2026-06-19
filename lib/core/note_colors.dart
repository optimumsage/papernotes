import 'package:flutter/material.dart';

/// A curated palette for note cards. Index 0 is the default ("no color").
/// Each swatch carries a light and dark variant so cards stay legible in
/// both themes.
class NoteSwatch {
  final String name;
  final Color light;
  final Color dark;

  const NoteSwatch(this.name, this.light, this.dark);
}

class NoteColors {
  NoteColors._();

  /// Ordered list of swatches. The integer `color` field on a note is an
  /// index into this list. Keep this list append-only so existing notes keep
  /// their color when new swatches are added.
  static const List<NoteSwatch> swatches = [
    NoteSwatch('Default', Color(0xFFFFFFFF), Color(0xFF1E1E22)),
    NoteSwatch('Coral', Color(0xFFFFE9E5), Color(0xFF4A2C2A)),
    NoteSwatch('Sand', Color(0xFFFFF3D6), Color(0xFF463A21)),
    NoteSwatch('Mint', Color(0xFFDFF6E8), Color(0xFF1F3D2E)),
    NoteSwatch('Sky', Color(0xFFE0F0FF), Color(0xFF20354A)),
    NoteSwatch('Lavender', Color(0xFFEDE6FF), Color(0xFF332B4A)),
    NoteSwatch('Blush', Color(0xFFFFE5F1), Color(0xFF45283A)),
    NoteSwatch('Sage', Color(0xFFEAF0DC), Color(0xFF313A26)),
    NoteSwatch('Slate', Color(0xFFE7ECF2), Color(0xFF2A323C)),
    NoteSwatch('Clay', Color(0xFFF6E2D2), Color(0xFF44342A)),
  ];

  static int get count => swatches.length;

  /// Background color for the given index in the current brightness.
  static Color background(int index, Brightness brightness) {
    final swatch = swatches[index.clamp(0, swatches.length - 1)];
    return brightness == Brightness.dark ? swatch.dark : swatch.light;
  }

  static String nameOf(int index) =>
      swatches[index.clamp(0, swatches.length - 1)].name;
}
