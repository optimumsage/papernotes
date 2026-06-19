import 'package:go_router/go_router.dart';

import 'data/models/note.dart';
import 'features/archive/archive_screen.dart';
import 'features/common/desktop_shell.dart';
import 'features/editor/editor_screen.dart';
import 'features/notes_list/notes_list_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/trash/trash_screen.dart';

/// App routes. The Notes / Archive / Trash screens live inside a [ShellRoute]
/// so the desktop side panel ([DesktopShell]) persists across them and only the
/// content swaps (no page-slide that would drag the whole window). They use
/// [NoTransitionPage] so switching is instant. The editor and settings are
/// top-level routes pushed full-screen over the shell.
final appRouter = GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          DesktopShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: NotesListScreen()),
        ),
        GoRoute(
          path: '/archive',
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: ArchiveScreen()),
        ),
        GoRoute(
          path: '/trash',
          pageBuilder: (_, _) => const NoTransitionPage(child: TrashScreen()),
        ),
      ],
    ),
    GoRoute(
      path: '/editor/:id',
      builder: (_, state) {
        final isNew = state.uri.queryParameters['new'] == '1';
        final typeParam = state.uri.queryParameters['type'];
        final type =
            typeParam == 'checklist' ? NoteType.checklist : NoteType.note;
        return EditorScreen(
          noteId: state.pathParameters['id']!,
          isNew: isNew,
          type: type,
          folderId: state.uri.queryParameters['folder'],
        );
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (_, _) => const SettingsScreen(),
    ),
  ],
);
