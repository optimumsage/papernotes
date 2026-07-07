import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/note_sort.dart';
import '../core/platform.dart';
import '../core/swipe_action.dart';
import '../data/attachments/attachment_store.dart';
import '../data/local/database.dart';
import '../data/models/folder.dart';
import '../data/models/note.dart';
import '../data/reminders/reminder_reconciler.dart';
import '../data/reminders/reminder_service.dart';
import '../data/repositories/folder_repository.dart';
import '../data/repositories/note_repository.dart';
import '../data/settings_service.dart';
import '../data/sync/drive_auth.dart';
import '../data/sync/drive_client.dart';
import '../data/sync/sync_engine.dart';
import '../data/update_service.dart';
import '../desktop/auto_start.dart';

/// Overridden in main() with the real instances created during bootstrap.
final prefsProvider = Provider<SharedPreferences>((_) {
  throw UnimplementedError('prefsProvider must be overridden');
});
final databaseProvider = Provider<AppDatabase>((_) {
  throw UnimplementedError('databaseProvider must be overridden');
});
final initialSettingsProvider = Provider<AppSettings>((_) {
  throw UnimplementedError('initialSettingsProvider must be overridden');
});
final attachmentStoreProvider = Provider<AttachmentStore>((_) {
  throw UnimplementedError('attachmentStoreProvider must be overridden');
});

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(prefsProvider)),
);

final noteRepositoryProvider = Provider<NoteRepository>(
  (ref) => NoteRepository(
    ref.watch(databaseProvider),
    attachmentStore: ref.watch(attachmentStoreProvider),
    // Push note changes to Drive shortly after they happen (debounced).
    onChanged: () => ref.read(syncControllerProvider.notifier).requestSync(),
  ),
);

final folderRepositoryProvider = Provider<FolderRepository>(
  (ref) => FolderRepository(
    ref.watch(databaseProvider),
    onChanged: () => ref.read(syncControllerProvider.notifier).requestSync(),
  ),
);

final driveAuthProvider = Provider<DriveAuth>(
  (ref) => DriveAuth(ref.watch(settingsServiceProvider)),
);

final driveClientProvider = Provider<DriveClient>((ref) {
  final client = DriveClient(ref.watch(driveAuthProvider));
  ref.onDispose(client.close);
  return client;
});

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(
    ref.watch(databaseProvider),
    ref.watch(driveClientProvider),
    ref.watch(settingsServiceProvider),
    ref.watch(attachmentStoreProvider),
  ),
);

final updateServiceProvider = Provider<UpdateService>((_) => UpdateService());

// ---- Reminders ----

/// Notification backend. Overridden in main() with an already-`init()`ed
/// instance so it's ready before the first reconcile / UI build.
final reminderServiceProvider = Provider<ReminderService>(
  (_) => ReminderService(),
);

/// Reconciles OS reminders with notes' reminder fields. Watches the active
/// notes stream so every create/edit/delete (and remote sync) converges here.
/// Kept alive by [PaperNotesApp] (`ref.watch`) so its subscription persists.
final reminderReconcilerProvider = Provider<ReminderReconciler>((ref) {
  final service = ref.read(reminderServiceProvider);
  final reconciler = ReminderReconciler(
    service,
    // A fired/past timed alarm is one-shot: clear it so it doesn't re-fire.
    onFired: (id) =>
        ref.read(noteRepositoryProvider).setReminder(id, ReminderType.none, null),
  );
  ref.onDispose(reconciler.dispose);
  // Service init is not awaited before the first frame; replay the latest
  // notes once notifications are actually ready.
  unawaited(service.whenReady.then((_) => reconciler.replay()));
  ref.listen<AsyncValue<List<Note>>>(
    activeNotesProvider,
    (_, next) {
      final notes = next.value;
      if (notes != null) reconciler.reconcile(notes);
    },
    fireImmediately: true,
  );
  return reconciler;
});

// ---- Notes lists (active / archive / trash) + search ----

final activeNotesProvider = StreamProvider<List<Note>>(
  (ref) => ref.watch(noteRepositoryProvider).watchActive(),
);
// Archive/Trash are autoDispose: drift re-runs every live watch query on any
// write to the notes table, so keeping these alive after leaving the screen
// would re-query + re-map all three lists on every autosave, forever.
final archivedNotesProvider = StreamProvider.autoDispose<List<Note>>(
  (ref) => ref.watch(noteRepositoryProvider).watchArchived(),
);
final trashedNotesProvider = StreamProvider.autoDispose<List<Note>>(
  (ref) => ref.watch(noteRepositoryProvider).watchTrashed(),
);

/// Live search text. A small Notifier (Riverpod 3 dropped StateProvider from
/// the main export).
final searchQueryProvider =
    NotifierProvider<SearchQuery, String>(SearchQuery.new);

class SearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

// ---- Folders ----

/// Live, non-deleted folders (sorted by name in the db query).
final foldersProvider = StreamProvider<List<Folder>>(
  (ref) => ref.watch(folderRepositoryProvider).watchFolders(),
);

/// The folder currently filtering the Notes screen, or null for "all notes".
final selectedFolderProvider =
    NotifierProvider<SelectedFolder, String?>(SelectedFolder.new);

class SelectedFolder extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

/// The currently-selected folder resolved to a [Folder], or null when no
/// folder filter is active (or the folder was removed).
final selectedFolderObjectProvider = Provider<Folder?>((ref) {
  final id = ref.watch(selectedFolderProvider);
  if (id == null) return null;
  final folders = ref.watch(foldersProvider).value ?? const [];
  for (final f in folders) {
    if (f.id == id) return f;
  }
  return null;
});

/// Active notes filtered by the selected folder + live search query, sorted
/// per the user's chosen SortMode (pinned always first).
final filteredNotesProvider = Provider<List<Note>>((ref) {
  var notes = ref.watch(activeNotesProvider).value ?? const [];
  final folderId = ref.watch(selectedFolderProvider);
  if (folderId != null) {
    // Only filter while the folder still exists (it may have been deleted on
    // another device and pulled in); otherwise fall back to showing all notes.
    final folders = ref.watch(foldersProvider).value ?? const [];
    if (folders.any((f) => f.id == folderId)) {
      notes = notes.where((n) => n.folderId == folderId).toList();
    }
  }
  final query = ref.watch(searchQueryProvider);
  final sortMode = ref.watch(
      settingsControllerProvider.select((s) => s.sortMode));
  return sortNotes(searchNotes(notes, query), sortMode);
});

/// Archived notes, searched + sorted the same way.
final filteredArchivedProvider = Provider.autoDispose<List<Note>>((ref) {
  final notes = ref.watch(archivedNotesProvider).value ?? const [];
  final query = ref.watch(searchQueryProvider);
  final sortMode = ref.watch(
      settingsControllerProvider.select((s) => s.sortMode));
  return sortNotes(searchNotes(notes, query), sortMode);
});

/// Trashed notes, searched + sorted the same way.
final filteredTrashedProvider = Provider.autoDispose<List<Note>>((ref) {
  final notes = ref.watch(trashedNotesProvider).value ?? const [];
  final query = ref.watch(searchQueryProvider);
  final sortMode = ref.watch(
      settingsControllerProvider.select((s) => s.sortMode));
  return sortNotes(searchNotes(notes, query), sortMode);
});

// ---- Settings ----

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  SettingsService get _service => ref.read(settingsServiceProvider);

  @override
  AppSettings build() => ref.read(initialSettingsProvider);

  Future<void> reload() async => state = await _service.load();

  Future<void> setThemeMode(ThemeMode mode) async {
    await _service.setThemeMode(mode);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setSyncEnabled(bool value) async {
    await _service.setSyncEnabled(value);
    state = state.copyWith(syncEnabled: value);
  }

  Future<void> setFontScale(double value) async {
    await _service.setFontScale(value);
    state = state.copyWith(fontScale: value);
  }

  Future<void> setSortMode(SortMode mode) async {
    await _service.setSortMode(mode);
    state = state.copyWith(sortMode: mode);
  }

  Future<void> setViewStyle(ViewStyle style) async {
    await _service.setViewStyle(style);
    state = state.copyWith(viewStyle: style);
  }

  Future<void> setDefaultColor(int index) async {
    await _service.setDefaultColor(index);
    state = state.copyWith(defaultColor: index);
  }

  Future<void> setSyncOnLaunch(bool value) async {
    await _service.setSyncOnLaunch(value);
    state = state.copyWith(syncOnLaunch: value);
  }

  Future<void> setAutoSyncEnabled(bool value) async {
    await _service.setAutoSyncEnabled(value);
    state = state.copyWith(autoSyncEnabled: value);
  }

  Future<void> setAutoSyncMinutes(int value) async {
    await _service.setAutoSyncMinutes(value);
    state = state.copyWith(autoSyncMinutes: value);
  }

  Future<void> setConfirmDelete(bool value) async {
    await _service.setConfirmDelete(value);
    state = state.copyWith(confirmDelete: value);
  }

  Future<void> setTrashRetentionDays(int value) async {
    await _service.setTrashRetentionDays(value);
    state = state.copyWith(trashRetentionDays: value);
  }

  Future<void> setPreviewLines(int value) async {
    await _service.setPreviewLines(value);
    state = state.copyWith(previewLines: value);
  }

  Future<void> setRuledLines(bool value) async {
    await _service.setRuledLines(value);
    state = state.copyWith(ruledLines: value);
  }

  Future<void> setLeftSwipeAction(SwipeAction action) async {
    await _service.setLeftSwipeAction(action);
    state = state.copyWith(leftSwipeAction: action);
  }

  Future<void> setRightSwipeAction(SwipeAction action) async {
    await _service.setRightSwipeAction(action);
    state = state.copyWith(rightSwipeAction: action);
  }

  /// Desktop only: toggle launching the app at login. Applies it to the OS
  /// (best-effort — never throws) and persists the preference.
  Future<void> setLaunchAtStartup(bool value) async {
    if (isDesktopPlatform) {
      await AutoStartService.instance.setEnabled(value);
    }
    await _service.setLaunchAtStartup(value);
    state = state.copyWith(launchAtStartup: value);
  }

  Future<void> setCredentials(String clientId, String clientSecret) async {
    await _service.setClientId(clientId.trim());
    if (clientSecret.isNotEmpty) {
      await _service.setClientSecret(clientSecret.trim());
    }
    await reload();
  }

  /// Refresh only `lastSyncedAt` after a sync. Deliberately not a full
  /// [reload]: that would rebuild the whole settings object (re-reading the
  /// encrypted secret store) seconds after every autosave-triggered sync.
  void markSyncedNow() {
    final at = _service.lastSyncedAt;
    if (at != null) state = state.copyWith(lastSyncedAt: at);
  }
}

// ---- Sync controller ----

enum SyncPhase { idle, running, success, error }

class SyncStatus {
  final SyncPhase phase;
  final String? message;
  const SyncStatus(this.phase, [this.message]);
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);

class SyncController extends Notifier<SyncStatus> {
  Timer? _debounce;

  @override
  SyncStatus build() {
    ref.onDispose(() => _debounce?.cancel());
    return const SyncStatus(SyncPhase.idle);
  }

  /// Debounced auto-sync after a note/folder mutation. Coalesces bursts (e.g.
  /// the editor's frequent autosaves) into a single sync a few seconds later.
  /// Quick mode: just pushes the dirty rows when possible instead of re-listing
  /// the whole Drive folder — remote changes are picked up by the launch /
  /// interval / manual syncs. No-ops at fire time when sync is disabled /
  /// signed out (see [syncNow]).
  void requestSync() {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(seconds: 3), () => unawaited(syncNow(quick: true)));
  }

  /// Sign in interactively, then enable sync and run the first sync.
  Future<void> signInAndEnable() async {
    final auth = ref.read(driveAuthProvider);
    try {
      state = const SyncStatus(SyncPhase.running, 'Signing in…');
      await auth.signIn();
      await ref.read(settingsControllerProvider.notifier).setSyncEnabled(true);
      await ref.read(settingsControllerProvider.notifier).reload();
      await syncNow();
    } on DriveAuthException catch (e) {
      state = SyncStatus(SyncPhase.error, e.message);
    } catch (e) {
      state = SyncStatus(SyncPhase.error, e.toString());
    }
  }

  Future<void> signOut() async {
    await ref.read(driveAuthProvider).signOut();
    await ref.read(settingsControllerProvider.notifier).setSyncEnabled(false);
    await ref.read(settingsControllerProvider.notifier).reload();
    state = const SyncStatus(SyncPhase.idle);
  }

  /// Run one sync cycle (full two-way, or push-only when [quick] and possible).
  /// Safe to call from UI buttons and timers.
  Future<void> syncNow({bool quick = false}) async {
    final settings = ref.read(settingsControllerProvider);
    if (!settings.syncEnabled || !settings.signedIn) return;
    try {
      state = const SyncStatus(SyncPhase.running, 'Syncing…');
      final result = await ref.read(syncEngineProvider).sync(quick: quick);
      ref.read(settingsControllerProvider.notifier).markSyncedNow();
      state = SyncStatus(
        SyncPhase.success,
        '↓${result.pulled} ↑${result.pushed}',
      );
    } on DriveAuthException catch (e) {
      state = SyncStatus(SyncPhase.error, e.message);
    } catch (e) {
      state = SyncStatus(SyncPhase.error, 'Sync failed: $e');
    }
  }
}
