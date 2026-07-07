import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/attachment.dart';
import '../models/folder.dart';
import '../models/note.dart';

part 'database.g.dart';

/// Drift table backing every note and checklist. `items` holds checklist rows
/// as a JSON string; `body` holds free text for plain notes. Sync bookkeeping
/// (driveFileId / remoteModifiedTime / dirty) lives alongside the content.
// Every live watch query filters on (deleted, status); the sync engine scans
// on dirty. Indexed so those stay cheap as the table grows (the watch queries
// re-run on every write to the table).
@TableIndex(name: 'idx_notes_deleted_status', columns: {#deleted, #status})
@TableIndex(name: 'idx_notes_dirty', columns: {#dirty})
@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // 'note' | 'checklist'
  TextColumn get title => text().nullable()();
  TextColumn get body => text().nullable()();
  TextColumn get items => text().nullable()(); // JSON list
  IntColumn get color => integer().withDefault(const Constant(0))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get folderId => text().nullable()(); // owning folder, or null
  TextColumn get status =>
      text().withDefault(const Constant('active'))(); // active|archived|trashed
  IntColumn get trashedAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get deletedAt => integer().nullable()();

  // Reminders
  TextColumn get reminderType =>
      text().withDefault(const Constant('none'))(); // none|alarm|pinned
  IntColumn get reminderAt => integer().nullable()(); // epoch ms (alarm)

  // Attachments (JSON metadata list; binaries live in the AttachmentStore.
  // Device-local — never synced, and preserved when remote updates land).
  TextColumn get attachments => text().nullable()();

  // Sync metadata
  TextColumn get driveFileId => text().nullable()();
  TextColumn get remoteModifiedTime => text().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Drift table backing folders. Flat (no nesting). Carries the same sync
/// bookkeeping as notes so folders round-trip through Drive identically.
@DataClassName('FolderRow')
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get deletedAt => integer().nullable()();

  // Sync metadata
  TextColumn get driveFileId => text().nullable()();
  TextColumn get remoteModifiedTime => text().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Notes, Folders])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(notes, notes.status);
            await m.addColumn(notes, notes.trashedAt);
          }
          if (from < 3) {
            await m.addColumn(notes, notes.folderId);
            await m.createTable(folders);
          }
          if (from < 4) {
            await m.addColumn(notes, notes.reminderType);
            await m.addColumn(notes, notes.reminderAt);
          }
          if (from < 5) {
            await m.addColumn(notes, notes.attachments);
            await m.createIndex(idxNotesDeletedStatus);
            await m.createIndex(idxNotesDirty);
          }
        },
      );

  // ---- Queries used by the UI ----

  /// Live notes in the given lifecycle state (tombstones always excluded),
  /// newest activity first with pinned on top. Default base ordering; the UI
  /// re-sorts per the user's chosen SortMode.
  Stream<List<Note>> _watchByStatus(NoteStatus status) {
    final query = select(notes)
      ..where((t) =>
          t.deleted.equals(false) & t.status.equals(status.name))
      ..orderBy([
        (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
      ]);
    return query.watch().map((rows) => rows.map(_toModel).toList());
  }

  Stream<List<Note>> watchActive() => _watchByStatus(NoteStatus.active);
  Stream<List<Note>> watchArchived() => _watchByStatus(NoteStatus.archived);
  Stream<List<Note>> watchTrashed() => _watchByStatus(NoteStatus.trashed);

  /// All trashed notes (used by emptyTrash / auto-empty).
  Future<List<Note>> trashedNotes() async {
    final rows = await (select(notes)
          ..where((t) =>
              t.deleted.equals(false) &
              t.status.equals(NoteStatus.trashed.name)))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<Note?> getNote(String id) async {
    final row = await (select(notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ---- Mutations ----

  Future<void> upsertNote(Note note, {required bool dirty}) async {
    // The sync engine records each attachment's uploaded `driveFileId` via
    // [setAttachments], out of band from whatever note snapshot a caller (e.g.
    // the open editor) is holding. Carry those ids forward so a stale save
    // can't wipe them and force a duplicate re-upload.
    final merged = await _withPreservedDriveIds(note);
    await into(notes)
        .insertOnConflictUpdate(_toCompanion(merged, dirty: dirty));
  }

  Future<Note> _withPreservedDriveIds(Note note) async {
    if (note.attachments.every((a) => a.driveFileId != null)) return note;
    final existing = await (select(notes)..where((t) => t.id.equals(note.id)))
        .getSingleOrNull();
    if (existing == null) return note;
    final byId = {
      for (final a in NoteAttachment.decodeList(existing.attachments))
        a.id: a.driveFileId,
    };
    final attachments = [
      for (final a in note.attachments)
        a.driveFileId == null && byId[a.id] != null
            ? a.copyWith(driveFileId: byId[a.id])
            : a,
    ];
    return note.copyWith(attachments: attachments);
  }

  Future<void> hardDelete(String id) {
    return (delete(notes)..where((t) => t.id.equals(id))).go();
  }

  // ---- Sync helpers ----

  Future<List<Note>> dirtyNotes() async {
    final rows = await (select(notes)..where((t) => t.dirty.equals(true))).get();
    return rows.map(_toModel).toList();
  }

  /// Dirty rows in raw form (includes sync columns) so the sync engine can
  /// push without a per-note re-query.
  Future<List<NoteRow>> dirtyRawNoteRows() =>
      (select(notes)..where((t) => t.dirty.equals(true))).get();

  Future<List<FolderRow>> dirtyRawFolderRows() =>
      (select(folders)..where((t) => t.dirty.equals(true))).get();

  /// Public row→model mapping for callers holding raw rows.
  Note noteFromRow(NoteRow row) => _toModel(row);
  Folder folderFromRow(FolderRow row) => _toFolderModel(row);

  /// Returns the raw row for a note (includes sync columns) or null.
  Future<NoteRow?> rawRow(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Every row including tombstones — used by the sync engine to diff against
  /// the remote appDataFolder listing.
  Future<List<NoteRow>> allRawRows() => select(notes).get();

  Future<void> setSyncMeta(
    String id, {
    required String driveFileId,
    required String? remoteModifiedTime,
    required bool dirty,
  }) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        driveFileId: Value(driveFileId),
        remoteModifiedTime: Value(remoteModifiedTime),
        dirty: Value(dirty),
      ),
    );
  }

  /// Apply a note that came down from Drive. Preserves the supplied sync
  /// metadata and marks the row clean (it already matches the remote). The
  /// remote attachments list (with each binary's `driveFileId`) is applied so
  /// this device knows what to download; the sync engine fetches any missing
  /// binaries afterwards.
  Future<void> applyRemote(
    Note note, {
    required String driveFileId,
    required String? remoteModifiedTime,
  }) {
    return into(notes).insertOnConflictUpdate(
      _toCompanion(note, dirty: false).copyWith(
        driveFileId: Value(driveFileId),
        remoteModifiedTime: Value(remoteModifiedTime),
      ),
    );
  }

  /// Overwrite just the `attachments` column (used by the sync engine to record
  /// the uploaded binaries' `driveFileId`s). Deliberately leaves `updatedAt`
  /// and `dirty` untouched so it never triggers a re-sync loop.
  Future<void> setAttachments(String id, List<NoteAttachment> attachments) {
    return (update(notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        attachments: Value(
          attachments.isEmpty ? null : NoteAttachment.encodeList(attachments),
        ),
      ),
    );
  }

  /// Tombstones whose retention window has elapsed — safe to purge.
  Future<List<Note>> expiredTombstones(int cutoffEpochMs) async {
    final rows = await (select(notes)
          ..where((t) =>
              t.deleted.equals(true) &
              t.deletedAt.isSmallerThanValue(cutoffEpochMs)))
        .get();
    return rows.map(_toModel).toList();
  }

  // ---- Folders ----

  /// Live, non-deleted folders ordered by name (case-insensitive).
  Stream<List<Folder>> watchFolders() {
    final query = select(folders)
      ..where((t) => t.deleted.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.name.lower())]);
    return query.watch().map((rows) => rows.map(_toFolderModel).toList());
  }

  Future<Folder?> getFolder(String id) async {
    final row =
        await (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toFolderModel(row);
  }

  Future<void> upsertFolder(Folder folder, {required bool dirty}) {
    return into(folders)
        .insertOnConflictUpdate(_toFolderCompanion(folder, dirty: dirty));
  }

  Future<void> hardDeleteFolder(String id) {
    return (delete(folders)..where((t) => t.id.equals(id))).go();
  }

  /// Notes currently filed under [folderId] (tombstones excluded). Used when a
  /// folder is deleted so its notes can be unfiled.
  Future<List<Note>> notesInFolder(String folderId) async {
    final rows = await (select(notes)
          ..where((t) => t.deleted.equals(false) & t.folderId.equals(folderId)))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<FolderRow?> rawFolderRow(String id) {
    return (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<List<FolderRow>> allRawFolderRows() => select(folders).get();

  Future<List<Folder>> dirtyFolders() async {
    final rows =
        await (select(folders)..where((t) => t.dirty.equals(true))).get();
    return rows.map(_toFolderModel).toList();
  }

  Future<void> setFolderSyncMeta(
    String id, {
    required String driveFileId,
    required String? remoteModifiedTime,
    required bool dirty,
  }) {
    return (update(folders)..where((t) => t.id.equals(id))).write(
      FoldersCompanion(
        driveFileId: Value(driveFileId),
        remoteModifiedTime: Value(remoteModifiedTime),
        dirty: Value(dirty),
      ),
    );
  }

  Future<void> applyRemoteFolder(
    Folder folder, {
    required String driveFileId,
    required String? remoteModifiedTime,
  }) {
    return into(folders).insertOnConflictUpdate(
      _toFolderCompanion(folder, dirty: false).copyWith(
        driveFileId: Value(driveFileId),
        remoteModifiedTime: Value(remoteModifiedTime),
      ),
    );
  }

  Future<List<Folder>> expiredFolderTombstones(int cutoffEpochMs) async {
    final rows = await (select(folders)
          ..where((t) =>
              t.deleted.equals(true) &
              t.deletedAt.isSmallerThanValue(cutoffEpochMs)))
        .get();
    return rows.map(_toFolderModel).toList();
  }

  // ---- Mapping ----

  Folder _toFolderModel(FolderRow row) => Folder(
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deleted: row.deleted,
        deletedAt: row.deletedAt,
      );

  FoldersCompanion _toFolderCompanion(Folder folder, {required bool dirty}) {
    return FoldersCompanion(
      id: Value(folder.id),
      name: Value(folder.name),
      createdAt: Value(folder.createdAt),
      updatedAt: Value(folder.updatedAt),
      deleted: Value(folder.deleted),
      deletedAt: Value(folder.deletedAt),
      dirty: Value(dirty),
    );
  }

  Note _toModel(NoteRow row) => Note(
        id: row.id,
        type: row.type == 'checklist' ? NoteType.checklist : NoteType.note,
        title: row.title,
        body: row.body,
        items: Note.itemsFromColumn(row.items),
        color: row.color,
        pinned: row.pinned,
        folderId: row.folderId,
        status: NoteStatus.values.firstWhere(
          (s) => s.name == row.status,
          orElse: () => NoteStatus.active,
        ),
        trashedAt: row.trashedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deleted: row.deleted,
        deletedAt: row.deletedAt,
        reminderType: ReminderType.values.firstWhere(
          (r) => r.name == row.reminderType,
          orElse: () => ReminderType.none,
        ),
        reminderAt: row.reminderAt,
        attachments: NoteAttachment.decodeList(row.attachments),
      );

  NotesCompanion _toCompanion(Note note, {required bool dirty}) {
    return NotesCompanion(
      id: Value(note.id),
      type: Value(note.type.name),
      title: Value(note.title),
      body: Value(note.body),
      items: Value(note.isChecklist ? note.itemsToColumn() : null),
      color: Value(note.color),
      pinned: Value(note.pinned),
      folderId: Value(note.folderId),
      status: Value(note.status.name),
      trashedAt: Value(note.trashedAt),
      createdAt: Value(note.createdAt),
      updatedAt: Value(note.updatedAt),
      deleted: Value(note.deleted),
      deletedAt: Value(note.deletedAt),
      reminderType: Value(note.reminderType.name),
      reminderAt: Value(note.reminderAt),
      attachments: Value(note.attachmentsToColumn()),
      dirty: Value(dirty),
    );
  }
}

/// Opens the database file in the platform's documents directory. On desktop
/// the bundled `sqlite3` FFI library is used; on Android `sqlite3_flutter_libs`
/// provides it.
LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'papernote.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
