import 'package:flutter/material.dart';

import '../../core/note_colors.dart';

/// Horizontal swatch row shown in a bottom sheet for picking a note color.
class ColorPickerSheet extends StatelessWidget {
  const ColorPickerSheet({super.key, required this.selected, required this.onPick});

  final int selected;
  final ValueChanged<int> onPick;

  static Future<void> show(
    BuildContext context, {
    required int selected,
    required ValueChanged<int> onPick,
  }) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => ColorPickerSheet(selected: selected, onPick: onPick),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Color', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: NoteColors.count,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final color = NoteColors.background(index, brightness);
                  final isSelected = index == selected;
                  return GestureDetector(
                    onTap: () {
                      onPick(index);
                      Navigator.of(context).pop();
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                          width: isSelected ? 3 : 1,
                        ),
                      ),
                      child: isSelected
                          ? Icon(Icons.check,
                              size: 20,
                              color: ThemeData.estimateBrightnessForColor(
                                          color) ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black87)
                          : (index == 0
                              ? Icon(Icons.format_color_reset_outlined,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.outline)
                              : null),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
