import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/note_sort.dart';
import '../../providers/providers.dart';
import '../common/app_drawer.dart';
import '../common/desktop_shell.dart';

/// Common chrome for the Notes / Archive / Trash screens: a modal navigation
/// drawer (mobile only — the permanent desktop side panel lives in
/// [DesktopShell]), a collapsible search field, and a compact actions cluster.
/// The body (which watches the relevant notes provider) is supplied by each
/// screen so search/sort changes flow through automatically.
class NotesScaffold extends ConsumerStatefulWidget {
  const NotesScaffold({
    super.key,
    required this.route,
    required this.title,
    required this.body,
    this.extraActions = const [],
    this.floatingActionButton,
  });

  final String route;
  final String title;
  final Widget body;
  final List<Widget> extraActions;
  final Widget? floatingActionButton;

  @override
  ConsumerState<NotesScaffold> createState() => _NotesScaffoldState();
}

class _NotesScaffoldState extends ConsumerState<NotesScaffold> {
  final _searchController = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        ref.read(searchQueryProvider.notifier).set('');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.read(settingsControllerProvider.notifier);
    final sortMode =
        ref.watch(settingsControllerProvider.select((s) => s.sortMode));
    final viewStyle =
        ref.watch(settingsControllerProvider.select((s) => s.viewStyle));
    final isWide = MediaQuery.sizeOf(context).width >= kWideBreakpoint;

    return Scaffold(
      // The permanent side panel (DesktopShell) hosts navigation on wide
      // layouts; only narrow layouts get the modal drawer.
      drawer: isWide ? null : AppDrawer(current: widget.route),
      appBar: AppBar(
        // No leading hamburger on wide, so give the title room off the divider.
        titleSpacing: isWide ? 20 : 0,
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search notes…'),
                onChanged: (v) =>
                    ref.read(searchQueryProvider.notifier).set(v),
              )
            : Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
          ...widget.extraActions,
          // Sort + view collapsed into one overflow menu to keep the bar
          // uncrowded (so the title isn't clipped on narrow Android screens).
          PopupMenuButton<Object>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (value) {
              if (value is SortMode) {
                ctrl.setSortMode(value);
              } else {
                ctrl.setViewStyle(viewStyle == ViewStyle.grid
                    ? ViewStyle.list
                    : ViewStyle.grid);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem<Object>(
                enabled: false,
                child: Text('Sort by'),
              ),
              for (final m in SortMode.values)
                CheckedPopupMenuItem<Object>(
                  value: m,
                  checked: m == sortMode,
                  child: Text(m.label),
                ),
              const PopupMenuDivider(),
              PopupMenuItem<Object>(
                value: 'view',
                child: Row(
                  children: [
                    Icon(viewStyle == ViewStyle.grid
                        ? Icons.view_agenda_outlined
                        : Icons.grid_view_outlined),
                    const SizedBox(width: 12),
                    Text(viewStyle == ViewStyle.grid
                        ? 'List view'
                        : 'Grid view'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: widget.body,
      floatingActionButton: widget.floatingActionButton,
    );
  }
}
