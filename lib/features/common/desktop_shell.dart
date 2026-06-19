import 'package:flutter/material.dart';

import 'app_drawer.dart';

/// At or above this width the navigation is a permanent side panel (desktop);
/// below it each screen falls back to a modal drawer (mobile).
const double kWideBreakpoint = 900;

/// Persistent shell around the Notes / Archive / Trash screens. On wide layouts
/// it renders the navigation side panel once and only swaps the [child] content
/// when the route changes — so selecting Notes/Archive/Trash/a folder updates
/// the content pane without sliding the whole window. On narrow layouts it's a
/// pass-through (each screen supplies its own modal drawer).
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.location, required this.child});

  /// Current top-level route ('/', '/archive', '/trash') — drives which nav
  /// item is highlighted.
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideBreakpoint;
    if (!isWide) return child;

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: AppDrawerContent(current: location),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: child),
      ],
    );
  }
}
