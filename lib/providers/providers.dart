import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/note_sort.dart';
import '../core/platform.dart';
import '../core/swipe_action.dart';
import '../data/attachments/attachment_store.dart';
import '../data/auth/app_lock_service.dart';
import '../data/crypto/encryption_service.dart';
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

/// The single encryption authority. Overridden in main() with the same
/// instance injected into [AppDatabase] so the at-rest mappers and the sync
/// engine share one key. A fresh instance is a disabled/no-op passthrough.
final encryptionServiceProvider = Provider<EncryptionService>((_) {
  throw UnimplementedError('encryptionServiceProvider must be overridden');
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
    ref.watch(encryptionServiceProvider),
  ),
);

final updateServiceProvider = Provider<UpdateService>((_) => UpdateService());

final appLockServiceProvider = Provider<AppLockService>((_) => AppLockService());

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

  /// Persist the encryption enabled flag + key fingerprint together, then
  /// reload so a null fingerprint (on disable) is reflected too.
  Future<void> applyEncryptionState(bool enabled, String? fingerprint) async {
    await _service.setEncryptionEnabled(enabled);
    await _service.setEncryptionKeyFingerprint(fingerprint);
    await reload();
  }

  // ---- App lock ----

  Future<void> setAppLockEnabled(bool value) async {
    await _service.setAppLockEnabled(value);
    state = state.copyWith(appLockEnabled: value);
  }

  Future<void> setAppLockBiometricEnabled(bool value) async {
    await _service.setAppLockBiometricEnabled(value);
    state = state.copyWith(appLockBiometricEnabled: value);
  }

  Future<void> setAppLockAutoLockMinutes(int value) async {
    await _service.setAppLockAutoLockMinutes(value);
    state = state.copyWith(appLockAutoLockMinutes: value);
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
    // Never sync while the unlock gate is armed — a quick push could otherwise
    // upload plaintext (or mis-enveloped ciphertext) under a locked/stale key.
    if (ref.read(encryptionControllerProvider).needsUnlock) {
      state = const SyncStatus(SyncPhase.idle, 'Locked');
      return;
    }
    try {
      state = const SyncStatus(SyncPhase.running, 'Syncing…');
      // On full syncs, detect account-level encryption first; if this device
      // can't read it, arm the unlock gate and skip pulling ciphertext.
      if (!quick) {
        final canSync = await ref
            .read(encryptionControllerProvider.notifier)
            .reconcileBeforeSync();
        if (!canSync) {
          state = const SyncStatus(SyncPhase.idle, 'Locked');
          return;
        }
      }
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

// ---- Encryption controller ----

/// Snapshot of the device's encryption state. [needsUnlock] drives the
/// full-screen unlock gate: encryption is on for the account but this device
/// doesn't hold the master key yet.
class EncryptionStatus {
  final bool enabled;
  final bool unlocked;
  const EncryptionStatus({required this.enabled, required this.unlocked});

  bool get needsUnlock => enabled && !unlocked;
}

final encryptionControllerProvider =
    NotifierProvider<EncryptionController, EncryptionStatus>(
        EncryptionController.new);

class EncryptionController extends Notifier<EncryptionStatus> {
  EncryptionService get _crypto => ref.read(encryptionServiceProvider);
  SettingsService get _settingsService => ref.read(settingsServiceProvider);
  AppDatabase get _db => ref.read(databaseProvider);
  SyncEngine get _engine => ref.read(syncEngineProvider);

  @override
  EncryptionStatus build() {
    final enabled = ref.watch(
        settingsControllerProvider.select((s) => s.encryptionEnabled));
    // main() unlocks the crypto service before the app builds when a key is
    // cached, so isUnlocked is authoritative here.
    return EncryptionStatus(enabled: enabled, unlocked: _crypto.isUnlocked);
  }

  void _refresh(bool enabled) =>
      state = EncryptionStatus(enabled: enabled, unlocked: _crypto.isUnlocked);

  /// Enable encryption on this device with a freshly-generated [key]: cache the
  /// key, encrypt the local database, upload the canary, and re-sync so every
  /// note re-uploads encrypted.
  Future<void> enableWithKey(String key) async {
    await _settingsService.setMasterKey(key);
    await _db.migrateEncryption(() => _crypto.unlock(key));
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(true, EncryptionService.fingerprint(key));
    // Encrypt already-synced attachment binaries in place under the new key.
    await _engine.reencryptAttachments();
    // Publish the canary if Drive is reachable; otherwise the next sync
    // (after sign-in) self-heals it via [reconcileBeforeSync].
    await _tryPublishCanary();
    _refresh(true);
    await ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Rotate to a new master key: re-encrypt everything under it, rewrite the
  /// canary (new fingerprint → other devices re-prompt), and re-sync.
  Future<void> changeKey(String newKey) async {
    await _settingsService.setMasterKey(newKey);
    await _db.migrateEncryption(() => _crypto.unlock(newKey));
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(true, EncryptionService.fingerprint(newKey));
    await _engine.reencryptAttachments();
    await _tryPublishCanary();
    _refresh(true);
    await ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Validate a typed-in master key against the remote canary and, if correct,
  /// adopt it on this device (cache key, encrypt any local plaintext notes) and
  /// re-sync. Returns false when the key is wrong.
  Future<bool> unlockWithKey(String key) async {
    if (!EncryptionService.isValidKey(key)) return false;
    final meta = await _engine.readEncryptionMeta();
    final check = meta?['check'];
    if (check is! String ||
        EncryptionService.tryDecryptWith(key, check) !=
            AppConfig.encryptionCanaryText) {
      return false;
    }
    // If this device already holds a (possibly older) key, load it so the
    // existing local rows decrypt correctly before we re-encrypt them under the
    // new key — the gate may have locked the service (key rotated elsewhere).
    // For a first-time adopt there's no cached key, so local rows are plaintext.
    final oldKey = await _settingsService.readMasterKey();
    if (oldKey != null && EncryptionService.isValidKey(oldKey)) {
      _crypto.unlock(oldKey);
    }
    await _settingsService.setMasterKey(key);
    await _db.migrateEncryption(() => _crypto.unlock(key));
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(true, EncryptionService.fingerprint(key));
    await _engine.reencryptAttachments();
    _refresh(true);
    await ref.read(syncControllerProvider.notifier).syncNow();
    return true;
  }

  /// Turn encryption off for the account: decrypt the local database, drop the
  /// canary + cached key, and re-sync so notes re-upload in the clear.
  Future<void> disable() async {
    await _db.migrateEncryption(() => _crypto.lock());
    // Decrypt already-synced attachment binaries in place (crypto is now
    // locked, so this re-uploads them as plaintext).
    await _engine.reencryptAttachments();
    // Flip local state BEFORE the network delete so a failed/offline delete
    // can't strand the device on the unlock gate.
    await _settingsService.setMasterKey(null);
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(false, null);
    _refresh(false);
    try {
      await _engine.deleteEncryptionMeta();
    } catch (_) {
      // Best-effort — re-run "Turn off" while online to drop the canary.
    }
    await ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Called before a full sync: detect account-level encryption via the canary.
  /// Returns true when it's safe to sync note data; false when this device must
  /// unlock first (encryption is on remotely but we can't read it), in which
  /// case the unlock gate is armed.
  Future<bool> reconcileBeforeSync() async {
    final Map<String, dynamic>? meta;
    try {
      meta = await _engine.readEncryptionMeta();
    } catch (_) {
      // Can't reach Drive — let the normal sync path surface the error.
      return true;
    }
    final settings = ref.read(settingsControllerProvider);
    if (meta == null) {
      // No canary on Drive yet. If this device is the encrypting source of
      // truth, publish it now so other devices learn the account is encrypted.
      if (_crypto.isUnlocked && settings.encryptionEnabled) {
        await _tryPublishCanary();
      }
      return true;
    }
    final fp = meta['fp'] as String?;
    final check = meta['check'];
    // Proceed only if the *loaded* key actually decrypts the canary — never
    // trust the persisted fingerprint alone (it can be ahead of a stale cached
    // key after a rotation elsewhere).
    if (_crypto.isUnlocked &&
        check is String &&
        _crypto.decryptString(check) == AppConfig.encryptionCanaryText) {
      return true;
    }
    // Encrypted remotely and we can't read it (new device, or the key was
    // rotated elsewhere). Arm the gate and skip syncing ciphertext we can't
    // decrypt.
    _crypto.lock();
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(true, fp);
    _refresh(true);
    return false;
  }

  /// Publish (create/overwrite) the Drive canary describing the current key.
  /// Best-effort: a failure (e.g. not signed in yet) is swallowed and retried
  /// by the next sync's [reconcileBeforeSync].
  Future<void> _tryPublishCanary() async {
    if (!_crypto.isUnlocked) return;
    try {
      await _engine.writeEncryptionMeta({
        'pnenc': 1,
        'fp': ref.read(settingsControllerProvider).encryptionKeyFingerprint,
        'check': _crypto.encryptString(AppConfig.encryptionCanaryText),
      });
    } catch (_) {
      // Retried on the next sync.
    }
  }
}

// ---- App-lock controller ----

/// Snapshot of the app-lock (privacy) gate. [locked] drives the full-screen
/// [AppLockScreen]. Independent of encryption — the two gates stack.
class AppLockStatus {
  final bool enabled;
  final bool locked;
  const AppLockStatus({required this.enabled, required this.locked});
}

final appLockControllerProvider =
    NotifierProvider<AppLockController, AppLockStatus>(AppLockController.new);

class AppLockController extends Notifier<AppLockStatus> {
  AppLockService get _service => ref.read(appLockServiceProvider);
  SettingsService get _settingsService => ref.read(settingsServiceProvider);
  SettingsController get _settings =>
      ref.read(settingsControllerProvider.notifier);

  @override
  AppLockStatus build() {
    // Read (not watch) the persisted flag: `enabled`/`locked` are driven
    // explicitly by this controller thereafter, so build() runs once and its
    // state persists for the app's lifetime. Cold start begins locked when the
    // lock is on, until the user authenticates.
    final enabled = ref.read(settingsControllerProvider).appLockEnabled;
    return AppLockStatus(enabled: enabled, locked: enabled);
  }

  /// Turn the lock on with a freshly-chosen [pin]. Stays unlocked (the user just
  /// set it up in Settings).
  Future<void> enableWithPin(String pin) async {
    await _settingsService
        .setAppLockPinHash(AppLockService.hashPin(pin, AppLockService.newSalt()));
    await _settings.setAppLockEnabled(true);
    state = const AppLockStatus(enabled: true, locked: false);
  }

  /// Replace the PIN (caller must have already verified the current one).
  Future<void> changePin(String pin) => _settingsService
      .setAppLockPinHash(AppLockService.hashPin(pin, AppLockService.newSalt()));

  /// Whether [pin] matches the stored hash.
  Future<bool> verifyPin(String pin) async =>
      AppLockService.verifyPin(pin, await _settingsService.readAppLockPinHash());

  /// Prompt for biometric auth; on success, unlock the gate.
  Future<bool> unlockWithBiometric() async {
    final ok = await _service.authenticate('Unlock PaperNotes');
    if (ok) unlock();
    return ok;
  }

  Future<void> setBiometricEnabled(bool value) =>
      _settings.setAppLockBiometricEnabled(value);

  /// Turn the lock off entirely (caller must have verified the PIN/biometric).
  /// Clears the stored PIN and biometric preference. Clear the `enabled` flag
  /// FIRST: if the process dies mid-way, the app boots unlocked rather than
  /// "enabled with no PIN" (which would be an unrecoverable lockout).
  Future<void> disable() async {
    await _settings.setAppLockEnabled(false);
    await _settings.setAppLockBiometricEnabled(false);
    await _settingsService.setAppLockPinHash(null);
    state = const AppLockStatus(enabled: false, locked: false);
  }

  /// Lock the app now (manual "Lock now" or an auto-lock trigger). No-op when
  /// the lock is disabled.
  void lock() {
    if (!state.enabled) return;
    state = AppLockStatus(enabled: state.enabled, locked: true);
  }

  void unlock() =>
      state = AppLockStatus(enabled: state.enabled, locked: false);
}
