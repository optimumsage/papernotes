import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';

part 'database.g.dart';

/// Drift table backing every note and checklist. `items` holds checklist rows
/// as a JSON string; `body` holds free text for plain notes. Sync bookkeeping
/// (driveFileId / remoteModifiedTime / dirty) lives alongside the content.
@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // 'note' | 'checklist'
  TextColumn get title => text().nullable()();
  TextColumn get body => text().nullable()();
  TextColumn get items => text().nullable()(); // JSON list
  IntColumn get color => integer().withDefault(const Constant(0))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get status =>
      text().withDefault(const Constant('active'))(); // active|archived|trashed
  IntColumn get trashedAt => integer().nullable()();
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

@DriftDatabase(tables: [Notes])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(notes, notes.status);
            await m.addColumn(notes, notes.trashedAt);
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

  Future<void> upsertNote(Note note, {required bool dirty}) {
    return into(notes).insertOnConflictUpdate(_toCompanion(note, dirty: dirty));
  }

  Future<void> hardDelete(String id) {
    return (delete(notes)..where((t) => t.id.equals(id))).go();
  }

  // ---- Sync helpers ----

  Future<List<Note>> dirtyNotes() async {
    final rows = await (select(notes)..where((t) => t.dirty.equals(true))).get();
    return rows.map(_toModel).toList();
  }

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
  /// metadata and marks the row clean (it already matches the remote).
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

  /// Tombstones whose retention window has elapsed — safe to purge.
  Future<List<Note>> expiredTombstones(int cutoffEpochMs) async {
    final rows = await (select(notes)
          ..where((t) =>
              t.deleted.equals(true) &
              t.deletedAt.isSmallerThanValue(cutoffEpochMs)))
        .get();
    return rows.map(_toModel).toList();
  }

  // ---- Mapping ----

  Note _toModel(NoteRow row) => Note(
        id: row.id,
        type: row.type == 'checklist' ? NoteType.checklist : NoteType.note,
        title: row.title,
        body: row.body,
        items: Note.itemsFromColumn(row.items),
        color: row.color,
        pinned: row.pinned,
        status: NoteStatus.values.firstWhere(
          (s) => s.name == row.status,
          orElse: () => NoteStatus.active,
        ),
        trashedAt: row.trashedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deleted: row.deleted,
        deletedAt: row.deletedAt,
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
      status: Value(note.status.name),
      trashedAt: Value(note.trashedAt),
      createdAt: Value(note.createdAt),
      updatedAt: Value(note.updatedAt),
      deleted: Value(note.deleted),
      deletedAt: Value(note.deletedAt),
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
