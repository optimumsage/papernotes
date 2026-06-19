import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/note_sort.dart';
import '../../providers/providers.dart';
import '../common/app_drawer.dart';

/// Common chrome for the Notes / Archive / Trash screens: navigation drawer,
/// a collapsible search field, and sort + grid/list controls in the app bar.
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

    return Scaffold(
      drawer: AppDrawer(current: widget.route),
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search notes…'),
                onChanged: (v) =>
                    ref.read(searchQueryProvider.notifier).set(v),
              )
            : Text(widget.title),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
          PopupMenuButton<SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: sortMode,
            onSelected: ctrl.setSortMode,
            itemBuilder: (_) => [
              for (final m in SortMode.values)
                CheckedPopupMenuItem(
                  value: m,
                  checked: m == sortMode,
                  child: Text(m.label),
                ),
            ],
          ),
          IconButton(
            tooltip: viewStyle == ViewStyle.grid ? 'List view' : 'Grid view',
            icon: Icon(viewStyle == ViewStyle.grid
                ? Icons.view_agenda_outlined
                : Icons.grid_view_outlined),
            onPressed: () => ctrl.setViewStyle(
                viewStyle == ViewStyle.grid ? ViewStyle.list : ViewStyle.grid),
          ),
          ...widget.extraActions,
        ],
      ),
      body: widget.body,
      floatingActionButton: widget.floatingActionButton,
    );
  }
}
