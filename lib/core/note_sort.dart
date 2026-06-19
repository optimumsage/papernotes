import '../data/models/note.dart';

/// How the notes grid is ordered.
enum SortMode { updated, created, titleAsc, color }

/// How the notes grid is laid out.
enum ViewStyle { grid, list }

extension SortModeLabel on SortMode {
  String get label => switch (this) {
        SortMode.updated => 'Last edited',
        SortMode.created => 'Date created',
        SortMode.titleAsc => 'Title (A–Z)',
        SortMode.color => 'Color',
      };
}

SortMode sortModeFromName(String? name) =>
    SortMode.values.firstWhere((m) => m.name == name,
        orElse: () => SortMode.updated);

ViewStyle viewStyleFromName(String? name) =>
    ViewStyle.values.firstWhere((v) => v.name == name,
        orElse: () => ViewStyle.grid);

/// Returns a new list sorted by [mode]. Pinned notes always come first; ties
/// fall back to most-recently-updated so ordering stays stable and sensible.
List<Note> sortNotes(List<Note> notes, SortMode mode) {
  final sorted = [...notes];
  int byUpdated(Note a, Note b) => b.updatedAt.compareTo(a.updatedAt);

  sorted.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final cmp = switch (mode) {
      SortMode.updated => byUpdated(a, b),
      SortMode.created => b.createdAt.compareTo(a.createdAt),
      SortMode.titleAsc =>
        (a.title ?? '').toLowerCase().compareTo((b.title ?? '').toLowerCase()),
      SortMode.color => a.color.compareTo(b.color),
    };
    return cmp != 0 ? cmp : byUpdated(a, b);
  });
  return sorted;
}
