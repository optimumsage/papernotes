import '../../core/constants.dart';
import '../local/database.dart';
import '../models/folder.dart';
import '../models/note.dart';
import '../settings_service.dart';
import 'drive_client.dart';

/// Drive file-name prefix marking a folder payload (`folder-<id>.json`). Note
/// payloads are plain `<id>.json`, so the prefix partitions the two on listing.
const _folderPrefix = 'folder-';

class SyncResult {
  final int pulled;
  final int pushed;
  final int purged;
  const SyncResult(this.pulled, this.pushed, this.purged);
}

/// Two-way Google Drive sync over the hidden appDataFolder. Resolution is
/// last-write-wins by each note's own `updatedAt` (not Drive's modifiedTime),
/// so an edit made on any device wins consistently. Deletions travel as
/// tombstones and the underlying files are purged after a retention window.
///
/// The engine is stateless between runs except for the per-row sync metadata
/// (`driveFileId`, `remoteModifiedTime`, `dirty`) persisted in the database.
class SyncEngine {
  SyncEngine(this._db, this._client, this._settings);

  final AppDatabase _db;
  final DriveClient _client;
  final SettingsService _settings;

  bool _running = false;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Runs a full pull → push → purge cycle. Reentrant calls are ignored.
  ///
  /// [quick] is the debounced after-edit path: when it is provably safe (see
  /// [_canQuickPush]) it just uploads the dirty rows and skips the full folder
  /// listing + pull + purge, which the launch / interval / manual syncs cover.
  Future<SyncResult> sync({bool quick = false}) async {
    if (_running) return const SyncResult(0, 0, 0);
    _running = true;
    try {
      if (quick) {
        final dirtyNotes = await _db.dirtyRawNoteRows();
        final dirtyFolders = await _db.dirtyRawFolderRows();
        if (await _canQuickPush(dirtyNotes, dirtyFolders)) {
          final pushed = await _pushFolders(const {}, rows: dirtyFolders) +
              await _push(const {}, rows: dirtyNotes);
          await _settings.setLastSyncedAt(_now);
          return SyncResult(0, pushed, 0);
        }
      }

      final remote = await _client.list();
      // Partition the remote listing into note files and folder files.
      final remoteNotes =
          remote.where((f) => !f.noteId.startsWith(_folderPrefix)).toList();
      final remoteFolders =
          remote.where((f) => f.noteId.startsWith(_folderPrefix)).toList();

      final remoteById = {for (final f in remoteNotes) f.noteId: f};
      final localById = {for (final r in await _db.allRawRows()) r.id: r};
      // Folder maps are keyed by the bare folder id (prefix stripped).
      final remoteFolderById = {
        for (final f in remoteFolders) _folderId(f.noteId): f
      };
      final localFolderById = {
        for (final r in await _db.allRawFolderRows()) r.id: r
      };

      // Folders pull first so notes referencing them resolve to a known folder.
      final pulled = await _pullFolders(remoteFolders, localFolderById) +
          await _pull(remoteNotes, localById);
      final pushed =
          await _pushFolders(remoteFolderById) + await _push(remoteById);
      final purged = await _purgeFolders() + await _purge();

      await _settings.setLastSyncedAt(_now);
      return SyncResult(pulled, pushed, purged);
    } finally {
      _running = false;
    }
  }

  /// True when pushing the dirty rows without a pull first cannot violate
  /// last-write-wins: every row already has a Drive file AND that file is
  /// unchanged since we last saw it (verified with one cheap metadata GET per
  /// row — the debounced after-edit sync typically has exactly one). Any
  /// unknown file, remote change, or a large dirty set falls back to the full
  /// pull-first cycle, which resolves conflicts by `updatedAt` as before.
  Future<bool> _canQuickPush(
      List<NoteRow> notes, List<FolderRow> folders) async {
    if (notes.length + folders.length > 5) return false;
    for (final row in notes) {
      if (row.driveFileId == null || row.remoteModifiedTime == null) {
        return false;
      }
      if (await _client.modifiedTime(row.driveFileId!) !=
          row.remoteModifiedTime) {
        return false;
      }
    }
    for (final row in folders) {
      if (row.driveFileId == null || row.remoteModifiedTime == null) {
        return false;
      }
      if (await _client.modifiedTime(row.driveFileId!) !=
          row.remoteModifiedTime) {
        return false;
      }
    }
    return true;
  }

  /// Download remote files that are new or newer than the local copy.
  Future<int> _pull(List<RemoteFile> remote, Map<String, NoteRow> localById) async {
    var pulled = 0;
    for (final file in remote) {
      final local = localById[file.noteId];

      // Skip files unchanged since we last saw them.
      if (local != null &&
          local.remoteModifiedTime != null &&
          local.remoteModifiedTime == file.modifiedTime) {
        continue;
      }

      final remoteNote = Note.fromJson(await _client.download(file.id));

      if (local == null || remoteNote.updatedAt > local.updatedAt) {
        await _db.applyRemote(
          remoteNote,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
        );
        pulled++;
      } else if (local.driveFileId == null) {
        // Local is newer (will be pushed) but we now know its file id.
        await _db.setSyncMeta(
          local.id,
          driveFileId: file.id,
          remoteModifiedTime: local.remoteModifiedTime,
          dirty: local.dirty,
        );
      }
    }
    return pulled;
  }

  /// Upload every locally-dirty note (creates or overwrites its Drive file).
  /// Re-reads dirty rows after the pull (unless [rows] is supplied by the
  /// quick path) so freshly-applied remotes aren't re-pushed.
  Future<int> _push(Map<String, RemoteFile> remoteById,
      {List<NoteRow>? rows}) async {
    var pushed = 0;
    for (final raw in rows ?? await _db.dirtyRawNoteRows()) {
      final note = _db.noteFromRow(raw);
      final existingId = raw.driveFileId ?? remoteById[note.id]?.id;

      final result = existingId == null
          ? await _client.create(note.id, note.encode())
          : await _client.update(existingId, note.id, note.encode());

      await _db.setSyncMeta(
        note.id,
        driveFileId: result.id,
        remoteModifiedTime: result.modifiedTime,
        dirty: false,
      );
      pushed++;
    }
    return pushed;
  }

  /// Hard-delete tombstones (local + remote) once retention has elapsed.
  Future<int> _purge() async {
    final cutoff = _now - AppConfig.tombstoneRetention.inMilliseconds;
    final expired = await _db.expiredTombstones(cutoff);
    for (final note in expired) {
      final raw = await _db.rawRow(note.id);
      if (raw?.driveFileId != null) {
        try {
          await _client.deleteFile(raw!.driveFileId!);
        } catch (_) {
          // Already gone remotely — fine to drop locally.
        }
      }
      await _db.hardDelete(note.id);
    }
    return expired.length;
  }

  // ---- Folders (mirror the note pull/push/purge, keyed by `folder-<id>`) ----

  /// Strip the `folder-` prefix from a remote file's noteId to recover the
  /// bare folder id.
  String _folderId(String prefixedId) => prefixedId.substring(_folderPrefix.length);

  /// The remote file name PaperNotes uses for a folder.
  String _folderFileName(String id) => '$_folderPrefix$id';

  Future<int> _pullFolders(
      List<RemoteFile> remote, Map<String, FolderRow> localById) async {
    var pulled = 0;
    for (final file in remote) {
      final id = _folderId(file.noteId);
      final local = localById[id];

      if (local != null &&
          local.remoteModifiedTime != null &&
          local.remoteModifiedTime == file.modifiedTime) {
        continue;
      }

      final remoteFolder = Folder.fromJson(await _client.download(file.id));

      if (local == null || remoteFolder.updatedAt > local.updatedAt) {
        await _db.applyRemoteFolder(
          remoteFolder,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
        );
        pulled++;
      } else if (local.driveFileId == null) {
        await _db.setFolderSyncMeta(
          local.id,
          driveFileId: file.id,
          remoteModifiedTime: local.remoteModifiedTime,
          dirty: local.dirty,
        );
      }
    }
    return pulled;
  }

  Future<int> _pushFolders(Map<String, RemoteFile> remoteById,
      {List<FolderRow>? rows}) async {
    var pushed = 0;
    for (final raw in rows ?? await _db.dirtyRawFolderRows()) {
      final folder = _db.folderFromRow(raw);
      final existingId = raw.driveFileId ?? remoteById[folder.id]?.id;
      final fileId = _folderFileName(folder.id);

      final result = existingId == null
          ? await _client.create(fileId, folder.encode())
          : await _client.update(existingId, fileId, folder.encode());

      await _db.setFolderSyncMeta(
        folder.id,
        driveFileId: result.id,
        remoteModifiedTime: result.modifiedTime,
        dirty: false,
      );
      pushed++;
    }
    return pushed;
  }

  Future<int> _purgeFolders() async {
    final cutoff = _now - AppConfig.tombstoneRetention.inMilliseconds;
    final expired = await _db.expiredFolderTombstones(cutoff);
    for (final folder in expired) {
      final raw = await _db.rawFolderRow(folder.id);
      if (raw?.driveFileId != null) {
        try {
          await _client.deleteFile(raw!.driveFileId!);
        } catch (_) {
          // Already gone remotely — fine to drop locally.
        }
      }
      await _db.hardDeleteFolder(folder.id);
    }
    return expired.length;
  }
}
