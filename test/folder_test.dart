import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/date_format.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/folder.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/repositories/folder_repository.dart';
import 'package:papernote/data/repositories/note_repository.dart';

void main() {
  group('Folder serialization', () {
    test('round-trips a folder through JSON', () {
      final folder = Folder(
        id: 'f1',
        name: 'Work',
        createdAt: 1000,
        updatedAt: 2000,
      );
      final decoded = Folder.decode(folder.encode());
      expect(decoded.id, 'f1');
      expect(decoded.name, 'Work');
      expect(decoded.createdAt, 1000);
      expect(decoded.updatedAt, 2000);
      expect(decoded.deleted, isFalse);
    });

    test('tombstone fields round-trip', () {
      final folder = Folder(
        id: 'f1',
        name: 'Old',
        createdAt: 0,
        updatedAt: 5,
        deleted: true,
        deletedAt: 5,
      );
      final decoded = Folder.decode(folder.encode());
      expect(decoded.deleted, isTrue);
      expect(decoded.deletedAt, 5);
    });
  });

  group('Note.folderId', () {
    test('survives JSON round-trip', () {
      final note = Note(
        id: 'n1',
        type: NoteType.note,
        folderId: 'f1',
        createdAt: 0,
        updatedAt: 0,
      );
      expect(Note.decode(note.encode()).folderId, 'f1');
    });

    test('missing folderId defaults to null (back-compat)', () {
      final decoded = Note.fromJson({
        'id': 'n1',
        'type': 'note',
        'createdAt': 0,
        'updatedAt': 0,
      });
      expect(decoded.folderId, isNull);
    });

    test('copyWith clearFolderId unfiles a note', () {
      final note = Note(
          id: 'n1',
          type: NoteType.note,
          folderId: 'f1',
          createdAt: 0,
          updatedAt: 0);
      expect(note.copyWith(clearFolderId: true).folderId, isNull);
      // Without clear, the existing value is retained.
      expect(note.copyWith().folderId, 'f1');
    });
  });

  group('FolderRepository + database', () {
    late AppDatabase db;
    late FolderRepository folders;
    late NoteRepository notes;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      folders = FolderRepository(db);
      notes = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('createFolder persists and marks dirty for sync', () async {
      final f = await folders.createFolder('Work');
      expect(f.name, 'Work');
      final dirty = await db.dirtyFolders();
      expect(dirty.map((x) => x.id), contains(f.id));
      expect((await db.getFolder(f.id))!.name, 'Work');
    });

    test('renameFolder updates the name', () async {
      final f = await folders.createFolder('Wrok');
      await folders.renameFolder(f.id, 'Work');
      expect((await db.getFolder(f.id))!.name, 'Work');
    });

    test('setFolder files and unfiles a note', () async {
      final f = await folders.createFolder('Work');
      await notes.save(notes.newDraft(NoteType.note, id: 'n1').copyWith(body: 'x'));
      await notes.setFolder('n1', f.id);
      expect((await db.getNote('n1'))!.folderId, f.id);
      await notes.setFolder('n1', null);
      expect((await db.getNote('n1'))!.folderId, isNull);
    });

    test('deleteFolder tombstones it and unfiles its notes', () async {
      final f = await folders.createFolder('Work');
      await notes.save(notes.newDraft(NoteType.note, id: 'n1').copyWith(body: 'x'));
      await notes.setFolder('n1', f.id);

      await folders.deleteFolder(f.id);

      // Folder is a tombstone (propagates the deletion on next sync).
      final row = await db.rawFolderRow(f.id);
      expect(row!.deleted, isTrue);
      expect(row.deletedAt, isNotNull);
      // The note is kept but unfiled.
      final note = await db.getNote('n1');
      expect(note!.folderId, isNull);
      expect(note.deleted, isFalse);
    });

    test('watchFolders excludes deleted folders', () async {
      final keep = await folders.createFolder('Keep');
      final gone = await folders.createFolder('Gone');
      await folders.deleteFolder(gone.id);
      final live = await folders.watchFolders().first;
      expect(live.map((x) => x.id), [keep.id]);
    });

    test('applyRemoteFolder with newer updatedAt wins and is clean', () async {
      final remote = Folder(
          id: 'f1', name: 'remote', createdAt: 0, updatedAt: 500);
      await db.applyRemoteFolder(remote,
          driveFileId: 'file1', remoteModifiedTime: 't1');
      final row = await db.rawFolderRow('f1');
      expect(row!.name, 'remote');
      expect(row.dirty, isFalse);
      expect(row.driveFileId, 'file1');
    });

    test('expiredFolderTombstones respects the cutoff', () async {
      final f = await folders.createFolder('Old');
      await folders.deleteFolder(f.id);
      // deletedAt is "now"; a far-future cutoff makes it expired.
      final expired = await db.expiredFolderTombstones(
          DateTime.now().millisecondsSinceEpoch + 1000);
      expect(expired.map((x) => x.id), contains(f.id));
      // A cutoff in the past leaves it pending.
      final none = await db.expiredFolderTombstones(0);
      expect(none, isEmpty);
    });
  });

  group('date_format', () {
    final base = DateTime(2026, 6, 19, 12, 0);
    int ms(DateTime d) => d.millisecondsSinceEpoch;

    test('fullDate formats day month year', () {
      expect(fullDate(ms(DateTime(2026, 6, 19))), '19 Jun 2026');
    });

    test('relativeTime buckets', () {
      expect(relativeTime(ms(base), now: base), 'just now');
      expect(
          relativeTime(ms(base.subtract(const Duration(minutes: 5))), now: base),
          '5m ago');
      expect(relativeTime(ms(base.subtract(const Duration(hours: 3))), now: base),
          '3h ago');
      expect(relativeTime(ms(base.subtract(const Duration(days: 1))), now: base),
          'yesterday');
      expect(relativeTime(ms(base.subtract(const Duration(days: 3))), now: base),
          '3 days ago');
      // Older than a week falls back to an absolute date.
      expect(
          relativeTime(ms(DateTime(2026, 1, 1)), now: base), '1 Jan 2026');
    });
  });
}
