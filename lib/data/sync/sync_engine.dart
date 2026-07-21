import 'dart:convert';

import '../../core/constants.dart';
import '../attachments/attachment_store.dart';
import '../crypto/encryption_service.dart';
import '../local/database.dart';
import '../models/attachment.dart';
import '../models/folder.dart';
import '../models/note.dart';
import '../settings_service.dart';
import 'drive_client.dart';

/// Drive file-name prefix marking a folder payload (`folder-<id>.json`). Note
/// payloads are plain `<id>.json`, so the prefix partitions the two on listing.
const _folderPrefix = 'folder-';

/// Drive file-name prefix for an attachment binary (`attach-<attachmentId>`).
/// These are handled by `driveFileId` from within note payloads, so they are
/// excluded from the note/folder partition on listing.
const _attachPrefix = 'attach-';

/// Drive file-name prefix for encryption metadata (`encryption-meta.json`).
/// Excluded from the note/folder/attachment partition on listing.
const _encryptionPrefix = 'encryption-';

/// Skip garbage-collecting attachment binaries newer than this — another
/// device may have just uploaded one whose owning note this device hasn't
/// pulled yet, so its file would look unreferenced here.
const _attachGcSafetyWindow = Duration(hours: 1);

class SyncResult {
  final int pulled;
  final int pushed;

  /// Rows dropped locally this cycle: expired tombstones purged, plus rows
  /// whose Drive file another device already purged (see [_reconcileMissing]).
  final int removed;

  const SyncResult(this.pulled, this.pushed, this.removed);

  bool get isEmpty => pulled == 0 && pushed == 0 && removed == 0;
}

/// Two-way Google Drive sync over the hidden appDataFolder. Resolution is
/// last-write-wins by each note's own `updatedAt` (not Drive's modifiedTime),
/// so an edit made on any device wins consistently — *except* for deletions,
/// which are terminal and always win over a live copy (see [_remoteWins]).
/// Deletions travel as tombstones and the underlying files are purged after a
/// retention window; a device that meets an already-purged file drops its local
/// row via [_reconcileMissing].
///
/// Every pull decision also advances the row's `remoteModifiedTime`, so a pair
/// of diverged devices converges in a single cycle instead of re-downloading
/// the same file forever.
///
/// The engine is stateless between runs except for the per-row sync metadata
/// (`driveFileId`, `remoteModifiedTime`, `dirty`) persisted in the database.
class SyncEngine {
  SyncEngine(this._db, this._client, this._settings, this._store, this._crypto);

  final AppDatabase _db;
  final DriveApi _client;
  final SettingsService _settings;
  final AttachmentStore _store;
  final EncryptionService _crypto;

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
      // Partition the remote listing: folder payloads, note payloads, and
      // attachment binaries (handled separately, via note `driveFileId`s).
      final remoteNotes = remote
          .where((f) =>
              !f.noteId.startsWith(_folderPrefix) &&
              !f.noteId.startsWith(_attachPrefix) &&
              !f.noteId.startsWith(_encryptionPrefix))
          .toList();
      final remoteFolders =
          remote.where((f) => f.noteId.startsWith(_folderPrefix)).toList();
      final remoteAttachments =
          remote.where((f) => f.noteId.startsWith(_attachPrefix)).toList();

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
      // Runs after the pull (so rows the pull just refreshed are clean and
      // present) but before the push, so a row whose file another device purged
      // is dropped rather than re-uploaded.
      final reconciled = await _reconcileMissing(remoteNotes, remoteFolders);
      final pushed =
          await _pushFolders(remoteFolderById) + await _push(remoteById);
      final purged = await _purgeFolders() + await _purge() + reconciled;
      // Reclaim attachment binaries no longer referenced by any note.
      await _gcAttachments(remoteAttachments);

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
    // A deletion always takes the full pull-first cycle. The quick path uploads
    // without pulling, so pushing a tombstone here could race another device's
    // concurrent edit — and pushing a *live* row here could overwrite a
    // tombstone this device hasn't seen yet, resurrecting a deleted note.
    if (notes.any((r) => r.deleted) || folders.any((r) => r.deleted)) {
      return false;
    }
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

  /// Which side of a conflict wins.
  ///
  /// A permanent delete is a *terminal* state and beats a live copy regardless
  /// of timestamps. Wall-clock values minted on different devices aren't
  /// comparable — a phone whose clock trails the desktop by even a second would
  /// otherwise lose its tombstone and see the note resurrected — and a note that
  /// refuses to die is a worse failure than a lost edit. Only when both sides
  /// agree on liveness does last-write-wins apply.
  ///
  /// Exact timestamp ties need a rule too, or two devices holding different
  /// content at the same `updatedAt` would each decide it was the winner and
  /// overwrite the other on alternate syncs, forever. A pending local edit
  /// ([localDirty]) wins — unpushed work is never discarded — and otherwise the
  /// remote wins, so a clean device adopts the shared copy and both settle.
  static bool _remoteWins({
    required bool remoteDeleted,
    required int remoteUpdatedAt,
    required bool localDeleted,
    required int localUpdatedAt,
    required bool localDirty,
  }) {
    if (remoteDeleted != localDeleted) return remoteDeleted;
    if (remoteUpdatedAt != localUpdatedAt) return remoteUpdatedAt > localUpdatedAt;
    return !localDirty;
  }

  /// Download remote files that are new, newer, or tombstoned.
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

      final remoteNote =
          Note.fromJson(_crypto.unwrapPayload(await _client.download(file.id)));

      if (local == null ||
          _remoteWins(
            remoteDeleted: remoteNote.deleted,
            remoteUpdatedAt: remoteNote.updatedAt,
            localDeleted: local.deleted,
            localUpdatedAt: local.updatedAt,
            localDirty: local.dirty,
          )) {
        await _db.applyRemote(
          remoteNote,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
        );
        await _downloadAttachments(remoteNote);
        pulled++;
      } else {
        // Local wins. Record this file's modifiedTime so we stop re-downloading
        // it every cycle, and force `dirty` so `_push` (which re-reads dirty
        // rows after the pull) overwrites the remote with our copy. The two must
        // happen together: advancing remoteModifiedTime without pushing would
        // silently swallow the remote change. This pair is what makes a diverged
        // device converge in one cycle instead of thrashing forever.
        await _db.setSyncMeta(
          local.id,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
          dirty: true,
        );
      }
    }
    return pulled;
  }

  /// Drop local rows whose Drive file is gone — another device's [_purge]
  /// removed it after the retention window, so this row is a leftover that
  /// would otherwise survive as a zombie (and be re-uploaded on its next edit).
  ///
  /// Deliberately conservative, because the failure mode is data loss:
  ///
  /// * only clean rows that we know were synced (`driveFileId != null`,
  ///   `dirty == false`) — unsynced or locally-edited work is never touched;
  /// * skipped entirely when the listing is empty, so a failed or truncated
  ///   listing can't read as "everything was purged";
  /// * skipped entirely when *none* of our synced file ids appear in the
  ///   listing, which means we're looking at a different Drive account rather
  ///   than at our own purges.
  Future<int> _reconcileMissing(
      List<RemoteFile> remoteNotes, List<RemoteFile> remoteFolders) async {
    if (remoteNotes.isEmpty && remoteFolders.isEmpty) return 0;
    final remoteIds = {
      for (final f in remoteNotes) f.id,
      for (final f in remoteFolders) f.id,
    };

    final noteRows = (await _db.allRawRows())
        .where((r) => r.driveFileId != null && !r.dirty)
        .toList();
    final folderRows = (await _db.allRawFolderRows())
        .where((r) => r.driveFileId != null && !r.dirty)
        .toList();
    if (noteRows.isEmpty && folderRows.isEmpty) return 0;

    // Do we recognize this account at all? If not a single one of our synced
    // files is present, this is not a purge — bail out rather than wipe.
    final recognized = noteRows.any((r) => remoteIds.contains(r.driveFileId)) ||
        folderRows.any((r) => remoteIds.contains(r.driveFileId));
    if (!recognized) return 0;

    var removed = 0;
    for (final row in noteRows) {
      if (remoteIds.contains(row.driveFileId)) continue;
      await _store.removeAllFor(row.id);
      await _db.hardDelete(row.id);
      removed++;
    }
    for (final row in folderRows) {
      if (remoteIds.contains(row.driveFileId)) continue;
      await _db.hardDeleteFolder(row.id);
      removed++;
    }
    return removed;
  }

  /// Upload every locally-dirty note (creates or overwrites its Drive file).
  /// Re-reads dirty rows after the pull (unless [rows] is supplied by the
  /// quick path) so freshly-applied remotes aren't re-pushed.
  Future<int> _push(Map<String, RemoteFile> remoteById,
      {List<NoteRow>? rows}) async {
    var pushed = 0;
    for (final raw in rows ?? await _db.dirtyRawNoteRows()) {
      // Upload any not-yet-uploaded attachment binaries first so the note
      // payload carries their driveFileIds.
      final note = await _uploadAttachments(_db.noteFromRow(raw));
      final existingId = raw.driveFileId ?? remoteById[note.id]?.id;

      final payload = _crypto.wrapPayload(note.encode());
      final result = existingId == null
          ? await _client.create(note.id, payload)
          : await _client.update(existingId, note.id, payload);

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

  /// Upload each attachment binary that has no `driveFileId` yet (and whose
  /// local file exists), recording the returned id back onto the note. Records
  /// the ids via [AppDatabase.setAttachments] (no `updatedAt`/`dirty` change)
  /// so it never triggers a re-sync loop.
  Future<Note> _uploadAttachments(Note note) async {
    if (note.attachments.isEmpty) return note;
    var changed = false;
    final updated = <NoteAttachment>[];
    for (final att in note.attachments) {
      final file = _store.fileFor(note.id, att);
      if (att.driveFileId != null || !await file.exists()) {
        updated.add(att);
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        final payload =
            _crypto.isUnlocked ? _crypto.encryptBytes(bytes) : bytes;
        final remote =
            await _client.createBinary('$_attachPrefix${att.id}', payload);
        updated.add(att.copyWith(driveFileId: remote.id));
        changed = true;
      } catch (_) {
        updated.add(att); // best-effort; retried next sync
      }
    }
    if (!changed) return note;
    await _db.setAttachments(note.id, updated);
    return note.copyWith(attachments: updated);
  }

  /// Fetch any attachment binaries referenced by [note] that aren't already on
  /// this device. Best-effort — a failed download just leaves a missing file
  /// (shown as a broken tile) to retry on the next sync.
  Future<void> _downloadAttachments(Note note) async {
    for (final att in note.attachments) {
      final fid = att.driveFileId;
      if (fid == null) continue;
      if (await _store.exists(note.id, att)) continue;
      try {
        final bytes = await _client.downloadBytes(fid);
        await _store.writeBytes(note.id, att, _crypto.maybeDecryptBytes(bytes));
      } catch (_) {
        // Retried next full sync.
      }
    }
  }

  /// Delete attachment binaries no longer referenced by any note. Guards
  /// against a concurrent-upload race by skipping files newer than
  /// [_attachGcSafetyWindow] (their owning note may not be pulled here yet).
  Future<void> _gcAttachments(List<RemoteFile> remoteAttachments) async {
    if (remoteAttachments.isEmpty) return;
    // Every attachment id referenced by any local row (tombstones included, so
    // a delete pending sync still protects its files until it's purged).
    final referenced = <String>{};
    for (final row in await _db.allRawRows()) {
      for (final att
          in NoteAttachment.decodeList(_crypto.maybeDecrypt(row.attachments))) {
        referenced.add(att.id);
      }
    }
    final cutoff =
        DateTime.now().toUtc().subtract(_attachGcSafetyWindow);
    for (final file in remoteAttachments) {
      final attId = file.noteId.substring(_attachPrefix.length);
      if (referenced.contains(attId)) continue;
      final modified = DateTime.tryParse(file.modifiedTime ?? '');
      if (modified != null && modified.toUtc().isAfter(cutoff)) continue;
      try {
        await _client.deleteFile(file.id);
      } catch (_) {
        // Retried next full sync.
      }
    }
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
      // Delete the note's attachment binaries (Drive + any local leftovers).
      for (final att in note.attachments) {
        if (att.driveFileId != null) {
          try {
            await _client.deleteFile(att.driveFileId!);
          } catch (_) {
            // Already gone remotely.
          }
        }
      }
      await _store.removeAllFor(note.id);
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

      final remoteFolder = Folder.fromJson(
          _crypto.unwrapPayload(await _client.download(file.id)));

      if (local == null ||
          _remoteWins(
            remoteDeleted: remoteFolder.deleted,
            remoteUpdatedAt: remoteFolder.updatedAt,
            localDeleted: local.deleted,
            localUpdatedAt: local.updatedAt,
            localDirty: local.dirty,
          )) {
        await _db.applyRemoteFolder(
          remoteFolder,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
        );
        pulled++;
      } else {
        // Local wins — converge rather than re-download forever. See `_pull`.
        await _db.setFolderSyncMeta(
          local.id,
          driveFileId: file.id,
          remoteModifiedTime: file.modifiedTime,
          dirty: true,
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

      final payload = _crypto.wrapPayload(folder.encode());
      final result = existingId == null
          ? await _client.create(fileId, payload)
          : await _client.update(existingId, fileId, payload);

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

  /// Re-upload every already-synced attachment binary in place under the
  /// current crypto state — encrypting them on enable/change, or decrypting
  /// them on disable. The on-disk copy is always plaintext, so re-uploading
  /// from disk with the active key produces the right ciphertext. Keeps each
  /// binary's Drive file id (no duplicate/orphan). Best-effort per file; a
  /// device that lacks a binary locally just skips it (another device owns it).
  Future<void> reencryptAttachments() async {
    for (final raw in await _db.allRawRows()) {
      final note = _db.noteFromRow(raw);
      for (final att in note.attachments) {
        final fid = att.driveFileId;
        if (fid == null) continue;
        final file = _store.fileFor(note.id, att);
        if (!await file.exists()) continue;
        try {
          final bytes = await file.readAsBytes();
          final payload =
              _crypto.isUnlocked ? _crypto.encryptBytes(bytes) : bytes;
          await _client.updateBinary(fid, payload);
        } catch (_) {
          // Best-effort — retried on a later re-key if it fails.
        }
      }
    }
  }

  // ---- Encryption metadata (the canary) ----

  /// The bare noteId of the canary file (`encryption-meta.json` minus `.json`).
  static const _encryptionMetaNoteId = 'encryption-meta';

  /// Fetch the account's encryption canary, or null when encryption isn't
  /// enabled remotely. Shape: `{"pnenc":1, "fp":fingerprint, "check":known
  /// text encrypted with the master key}`.
  Future<Map<String, dynamic>?> readEncryptionMeta() async {
    final file = await _encryptionMetaFile();
    if (file == null) return null;
    return _client.download(file.id);
  }

  /// Create or overwrite the canary describing the current master key.
  Future<void> writeEncryptionMeta(Map<String, dynamic> meta) async {
    final content = jsonEncode(meta);
    final existing = await _encryptionMetaFile();
    if (existing == null) {
      await _client.create(_encryptionMetaNoteId, content);
    } else {
      await _client.update(existing.id, _encryptionMetaNoteId, content);
    }
  }

  /// Remove the canary (used when disabling encryption for the account).
  Future<void> deleteEncryptionMeta() async {
    final file = await _encryptionMetaFile();
    if (file != null) await _client.deleteFile(file.id);
  }

  Future<RemoteFile?> _encryptionMetaFile() async {
    for (final f in await _client.list()) {
      if (f.noteId == _encryptionMetaNoteId) return f;
    }
    return null;
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
