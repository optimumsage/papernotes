import 'package:go_router/go_router.dart';

import 'data/models/note.dart';
import 'features/archive/archive_screen.dart';
import 'features/editor/editor_screen.dart';
import 'features/notes_list/notes_list_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/trash/trash_screen.dart';

/// App routes. The editor is reached with a note id; a fresh draft is created
/// by the list screen before navigating so the editor always has a real id.
final appRouter = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const NotesListScreen(),
      routes: [
        GoRoute(
          path: 'editor/:id',
          builder: (_, state) {
            final isNew = state.uri.queryParameters['new'] == '1';
            final typeParam = state.uri.queryParameters['type'];
            final type =
                typeParam == 'checklist' ? NoteType.checklist : NoteType.note;
            return EditorScreen(
              noteId: state.pathParameters['id']!,
              isNew: isNew,
              type: type,
            );
          },
        ),
        GoRoute(
          path: 'settings',
          builder: (_, _) => const SettingsScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/archive',
      builder: (_, _) => const ArchiveScreen(),
    ),
    GoRoute(
      path: '/trash',
      builder: (_, _) => const TrashScreen(),
    ),
  ],
);
