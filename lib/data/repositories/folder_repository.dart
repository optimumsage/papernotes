import 'package:uuid/uuid.dart';

import '../local/database.dart';
import '../models/folder.dart';

/// Entry point the UI uses to read and mutate folders. Every write stamps
/// `updatedAt` and marks the row `dirty` so the sync engine pushes it. Folders
/// are flat (no nesting) and never talk to Drive directly.
class FolderRepository {
  FolderRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Stream<List<Folder>> watchFolders() => _db.watchFolders();

  Future<Folder?> getFolder(String id) => _db.getFolder(id);

  /// Create a new folder and persist it immediately.
  Future<Folder> createFolder(String name) async {
    final now = _now;
    final folder = Folder(
      id: _uuid.v4(),
      name: name.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertFolder(folder, dirty: true);
    return folder;
  }

  Future<void> renameFolder(String id, String name) async {
    final folder = await _db.getFolder(id);
    if (folder == null) return;
    await _db.upsertFolder(
      folder.copyWith(name: name.trim(), updatedAt: _now),
      dirty: true,
    );
  }

  /// Tombstone a folder and unfile every note it held (notes fall back to the
  /// unfiled list rather than disappearing). The tombstone propagates the
  /// deletion to other devices; the row + remote file are purged after the
  /// retention window.
  Future<void> deleteFolder(String id) async {
    final folder = await _db.getFolder(id);
    if (folder == null) return;
    final now = _now;
    for (final note in await _db.notesInFolder(id)) {
      await _db.upsertNote(
        note.copyWith(clearFolderId: true, updatedAt: now),
        dirty: true,
      );
    }
    await _db.upsertFolder(
      folder.copyWith(deleted: true, deletedAt: now, updatedAt: now),
      dirty: true,
    );
  }
}
