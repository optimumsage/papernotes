import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/note_sort.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/checklist_item.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/repositories/note_repository.dart';

Note _n(String id,
        {String? title,
        int updatedAt = 0,
        int createdAt = 0,
        int color = 0,
        bool pinned = false}) =>
    Note(
      id: id,
      type: NoteType.note,
      title: title,
      color: color,
      pinned: pinned,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

void main() {
  group('Note serialization', () {
    test('round-trips a note through JSON', () {
      final note = Note(
        id: 'abc',
        type: NoteType.note,
        title: 'Hello',
        body: 'World',
        color: 3,
        createdAt: 1000,
        updatedAt: 2000,
      );
      final decoded = Note.decode(note.encode());
      expect(decoded.id, 'abc');
      expect(decoded.title, 'Hello');
      expect(decoded.body, 'World');
      expect(decoded.color, 3);
      expect(decoded.updatedAt, 2000);
    });

    test('round-trips a checklist with items', () {
      final note = Note(
        id: 'c1',
        type: NoteType.checklist,
        title: 'Groceries',
        items: [
          ChecklistItem(id: 'i1', text: 'Milk', checked: true),
          ChecklistItem(id: 'i2', text: 'Eggs'),
        ],
        createdAt: 1,
        updatedAt: 2,
      );
      final decoded = Note.decode(note.encode());
      expect(decoded.isChecklist, isTrue);
      expect(decoded.items.length, 2);
      expect(decoded.items.first.checked, isTrue);
      expect(decoded.items[1].text, 'Eggs');
    });
  });

  group('isEmpty rules', () {
    test('note with no title and no body is empty', () {
      final n = Note(
          id: 'x', type: NoteType.note, createdAt: 0, updatedAt: 0);
      expect(n.isEmpty, isTrue);
    });

    test('checklist with a typed item is not empty', () {
      final n = Note(
        id: 'x',
        type: NoteType.checklist,
        items: [ChecklistItem(id: 'i', text: 'a')],
        createdAt: 0,
        updatedAt: 0,
      );
      expect(n.isEmpty, isFalse);
    });
  });

  group('search', () {
    final notes = [
      Note(
          id: '1',
          type: NoteType.note,
          title: 'Shopping',
          body: 'buy milk',
          createdAt: 0,
          updatedAt: 0),
      Note(
        id: '2',
        type: NoteType.checklist,
        title: 'Trip',
        items: [ChecklistItem(id: 'i', text: 'passport')],
        createdAt: 0,
        updatedAt: 0,
      ),
    ];

    test('matches body text case-insensitively', () {
      expect(searchNotes(notes, 'MILK').single.id, '1');
    });

    test('matches checklist item text', () {
      expect(searchNotes(notes, 'passport').single.id, '2');
    });

    test('empty query returns all', () {
      expect(searchNotes(notes, '   ').length, 2);
    });
  });

  group('repository + database', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('save persists and marks dirty for sync', () async {
      final draft = repo.newDraft(NoteType.note, id: 'n1')
          .copyWith(body: 'hi');
      await repo.save(draft);

      final dirty = await db.dirtyNotes();
      expect(dirty.map((n) => n.id), contains('n1'));
    });

    test('moveToTrash sets status=trashed (recoverable, not a tombstone)',
        () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'n1').copyWith(body: 'hi'));
      await repo.moveToTrash('n1');

      final note = await db.getNote('n1');
      expect(note!.status, NoteStatus.trashed);
      expect(note.trashedAt, isNotNull);
      expect(note.deleted, isFalse); // still recoverable
    });

    test('restore returns a trashed note to active', () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'n1').copyWith(body: 'hi'));
      await repo.moveToTrash('n1');
      await repo.restore('n1');

      final note = await db.getNote('n1');
      expect(note!.status, NoteStatus.active);
      expect(note.trashedAt, isNull);
    });

    test('archive / unarchive toggle the archived status', () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'n1').copyWith(body: 'hi'));
      await repo.archive('n1');
      expect((await db.getNote('n1'))!.status, NoteStatus.archived);
      await repo.unarchive('n1');
      expect((await db.getNote('n1'))!.status, NoteStatus.active);
    });

    test('deletePermanently sets the sync tombstone', () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'n1').copyWith(body: 'hi'));
      await repo.deletePermanently('n1');

      final row = await db.rawRow('n1');
      expect(row!.deleted, isTrue);
      expect(row.deletedAt, isNotNull);
    });

    test('emptyTrash tombstones every trashed note only', () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'a').copyWith(body: 'a'));
      await repo.save(
          repo.newDraft(NoteType.note, id: 'b').copyWith(body: 'b'));
      await repo.moveToTrash('a');
      await repo.emptyTrash();

      expect((await db.rawRow('a'))!.deleted, isTrue); // was trashed
      expect((await db.rawRow('b'))!.deleted, isFalse); // active, untouched
    });

    test('watchActive excludes archived and trashed notes', () async {
      await repo.save(
          repo.newDraft(NoteType.note, id: 'a').copyWith(body: 'a'));
      await repo.save(
          repo.newDraft(NoteType.note, id: 'b').copyWith(body: 'b'));
      await repo.archive('b');

      final active = await repo.watchActive().first;
      expect(active.map((n) => n.id), ['a']);
      final archived = await repo.watchArchived().first;
      expect(archived.map((n) => n.id), ['b']);
    });

    test('applyRemote with newer updatedAt wins and is clean', () async {
      await repo.save(repo.newDraft(NoteType.note, id: 'n1')
          .copyWith(body: 'local', updatedAt: 100));

      final remote = Note(
        id: 'n1',
        type: NoteType.note,
        body: 'remote',
        createdAt: 0,
        updatedAt: 500,
      );
      await db.applyRemote(remote,
          driveFileId: 'file1', remoteModifiedTime: 't1');

      final result = await db.getNote('n1');
      expect(result!.body, 'remote');
      final row = await db.rawRow('n1');
      expect(row!.dirty, isFalse);
      expect(row.driveFileId, 'file1');
    });
  });

  group('sortNotes', () {
    test('pinned notes always come first', () {
      final notes = [
        _n('a', updatedAt: 100),
        _n('b', updatedAt: 200, pinned: true),
      ];
      expect(sortNotes(notes, SortMode.updated).map((n) => n.id), ['b', 'a']);
    });

    test('updated sorts most-recent first', () {
      final notes = [_n('a', updatedAt: 100), _n('b', updatedAt: 300)];
      expect(sortNotes(notes, SortMode.updated).map((n) => n.id), ['b', 'a']);
    });

    test('created sorts newest-created first', () {
      final notes = [_n('a', createdAt: 300), _n('b', createdAt: 100)];
      expect(sortNotes(notes, SortMode.created).map((n) => n.id), ['a', 'b']);
    });

    test('titleAsc sorts alphabetically, case-insensitive', () {
      final notes = [_n('a', title: 'Banana'), _n('b', title: 'apple')];
      expect(sortNotes(notes, SortMode.titleAsc).map((n) => n.id), ['b', 'a']);
    });

    test('color sorts by palette index', () {
      final notes = [_n('a', color: 3), _n('b', color: 1)];
      expect(sortNotes(notes, SortMode.color).map((n) => n.id), ['b', 'a']);
    });
  });

  group('NoteStatus serialization', () {
    test('archived status round-trips through JSON', () {
      final note = Note(
        id: 'x',
        type: NoteType.note,
        status: NoteStatus.archived,
        trashedAt: 42,
        createdAt: 0,
        updatedAt: 0,
      );
      final decoded = Note.decode(note.encode());
      expect(decoded.status, NoteStatus.archived);
      expect(decoded.trashedAt, 42);
    });

    test('missing status defaults to active (back-compat with v1 files)', () {
      final decoded = Note.fromJson({
        'id': 'x',
        'type': 'note',
        'createdAt': 0,
        'updatedAt': 0,
      });
      expect(decoded.status, NoteStatus.active);
    });
  });
}
