import '../../core/constants.dart';
import '../local/database.dart';
import '../models/note.dart';
import '../settings_service.dart';
import 'drive_client.dart';

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
  Future<SyncResult> sync() async {
    if (_running) return const SyncResult(0, 0, 0);
    _running = true;
    try {
      final remote = await _client.list();
      final remoteById = {for (final f in remote) f.noteId: f};
      final localById = {for (final r in await _db.allRawRows()) r.id: r};

      final pulled = await _pull(remote, localById);
      final pushed = await _push(remoteById);
      final purged = await _purge();

      await _settings.setLastSyncedAt(_now);
      return SyncResult(pulled, pushed, purged);
    } finally {
      _running = false;
    }
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
  /// Re-reads dirty rows after the pull so freshly-applied remotes aren't
  /// re-pushed.
  Future<int> _push(Map<String, RemoteFile> remoteById) async {
    var pushed = 0;
    for (final note in await _db.dirtyNotes()) {
      final raw = await _db.rawRow(note.id);
      final existingId = raw?.driveFileId ?? remoteById[note.id]?.id;

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
}
