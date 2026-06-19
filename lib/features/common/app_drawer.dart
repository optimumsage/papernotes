import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Slide-out navigation shared by the Notes, Archive, and Trash screens.
/// The entry matching [current] is highlighted.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.current});

  /// One of '/', '/archive', '/trash'.
  final String current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Row(
                children: [
                  Icon(Icons.sticky_note_2_rounded,
                      color: theme.colorScheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Text('PaperNotes',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            _tile(context, Icons.sticky_note_2_outlined, 'Notes', '/'),
            _tile(context, Icons.archive_outlined, 'Archive', '/archive'),
            _tile(context, Icons.delete_outline, 'Trash', '/trash'),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                context.push('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(
      BuildContext context, IconData icon, String label, String route) {
    final selected = current == route;
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon,
          color: selected ? theme.colorScheme.primary : null),
      title: Text(label,
          style: TextStyle(
            color: selected ? theme.colorScheme.primary : null,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          )),
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      onTap: () {
        Navigator.pop(context);
        if (!selected) context.go(route);
      },
    );
  }
}
