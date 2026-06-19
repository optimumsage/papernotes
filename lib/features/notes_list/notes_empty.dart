import 'package:flutter/material.dart';

/// Centered empty-state placeholder shared by the Notes, Archive, and Trash
/// screens.
class NotesEmpty extends StatelessWidget {
  const NotesEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.outline)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle!,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
        ],
      ),
    );
  }
}
