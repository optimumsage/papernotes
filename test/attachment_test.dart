import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/attachments/attachment_store.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/attachment.dart';
import 'package:papernote/data/models/note.dart';

void main() {
  group('NoteAttachment', () {
    test('kind derives from the stored extension', () {
      NoteAttachment att(String fileName) => NoteAttachment(
          id: 'a', name: 'n', fileName: fileName, size: 1, createdAt: 1);
      expect(att('a.jpg').kind, AttachmentKind.image);
      expect(att('a.PNG'.toLowerCase()).kind, AttachmentKind.image);
      expect(att('a.pdf').kind, AttachmentKind.pdf);
      expect(att('a.docx').kind, AttachmentKind.other);
      expect(att('a').kind, AttachmentKind.other);
    });

    test('encodeList/decodeList round-trip', () {
      const original = [
        NoteAttachment(
            id: 'a1', name: 'doc.pdf', fileName: 'a1.pdf', size: 42, createdAt: 7),
        NoteAttachment(
            id: 'a2', name: 'pic.jpg', fileName: 'a2.jpg', size: 9, createdAt: 8),
      ];
      final decoded =
          NoteAttachment.decodeList(NoteAttachment.encodeList(original));
      expect(decoded.length, 2);
      expect(decoded[0].id, 'a1');
      expect(decoded[0].name, 'doc.pdf');
      expect(decoded[1].fileName, 'a2.jpg');
      expect(decoded[1].size, 9);
      expect(NoteAttachment.decodeList(null), isEmpty);
      expect(NoteAttachment.decodeList(''), isEmpty);
    });

    test('a note with only an attachment is not empty (not discarded)', () {
      const note = Note(id: 'n', type: NoteType.note, createdAt: 1, updatedAt: 1);
      expect(note.isEmpty, isTrue);
      final withAtt = note.copyWith(attachments: const [
        NoteAttachment(
            id: 'a', name: 'f.pdf', fileName: 'a.pdf', size: 1, createdAt: 1),
      ]);
      expect(withAtt.isEmpty, isFalse);
    });

    test('attachments (with driveFileId) round-trip through the Drive payload',
        () {
      final note = const Note(
              id: 'n', type: NoteType.note, createdAt: 1, updatedAt: 1)
          .copyWith(attachments: const [
        NoteAttachment(
            id: 'a',
            name: 'f.pdf',
            fileName: 'a.pdf',
            size: 1,
            createdAt: 1,
            driveFileId: 'drive-123'),
      ]);
      final decoded = Note.decode(note.encode());
      expect(decoded.attachments.single.id, 'a');
      expect(decoded.attachments.single.driveFileId, 'drive-123');
    });
  });

  group('AttachmentStore', () {
    late Directory root;
    late AttachmentStore store;

    setUp(() {
      root = Directory.systemTemp.createTempSync('papernote_att_test');
      store = AttachmentStore(root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('import copies the file and remove deletes it', () async {
      final src = File('${root.path}/src.txt')..writeAsStringSync('hello');
      final att = await store.import('note1', src.path);

      expect(att.name, 'src.txt');
      expect(att.fileName, endsWith('.txt'));
      expect(att.size, 5);
      final stored = store.fileFor('note1', att);
      expect(stored.existsSync(), isTrue);
      expect(stored.readAsStringSync(), 'hello');

      await store.remove('note1', att);
      expect(stored.existsSync(), isFalse);
      // Removing again is a no-op, not an error.
      await store.remove('note1', att);
    });

    test('import resolves file:// URIs (document scanner output)', () async {
      final src = File('${root.path}/scan.pdf')..writeAsStringSync('pdf');
      final att = await store.import(
          'note1', Uri.file(src.path).toString(), displayName: 'Scan.pdf');
      expect(att.name, 'Scan.pdf');
      expect(store.fileFor('note1', att).existsSync(), isTrue);
    });

    test('sweepOrphans removes directories for dead notes only', () async {
      final src = File('${root.path}/f.txt')..writeAsStringSync('x');
      final keep = await store.import('live', src.path);
      await store.import('gone', src.path);

      // Zero guard window so the just-created dirs are eligible in the test.
      await store.sweepOrphans((id) async => id == 'live',
          recentGuard: Duration.zero);

      expect(store.dirFor('gone').existsSync(), isFalse);
      expect(store.fileFor('live', keep).existsSync(), isTrue);
    });

    test('sweepOrphans never touches recently-created directories', () async {
      final src = File('${root.path}/f.txt')..writeAsStringSync('x');
      // Simulates an attach-in-progress: directory exists, note row not yet
      // saved — liveness reports false but the fresh mtime must protect it.
      final att = await store.import('brand-new', src.path);

      await store.sweepOrphans((_) async => false);

      expect(store.fileFor('brand-new', att).existsSync(), isTrue);
    });
  });

  group('database attachments column', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    const att = NoteAttachment(
        id: 'a1', name: 'f.pdf', fileName: 'a1.pdf', size: 3, createdAt: 1);

    test('attachments round-trip through the notes table', () async {
      final note = const Note(
              id: 'n1', type: NoteType.note, body: 'b', createdAt: 1, updatedAt: 1)
          .copyWith(attachments: const [att]);
      await db.upsertNote(note, dirty: true);
      final loaded = await db.getNote('n1');
      expect(loaded!.attachments.single.id, 'a1');
      expect(loaded.attachments.single.name, 'f.pdf');
    });

    test('applyRemote applies the remote attachments list', () async {
      await db.upsertNote(
        const Note(
                id: 'n1', type: NoteType.note, body: 'old', createdAt: 1, updatedAt: 1)
            .copyWith(attachments: const [att]),
        dirty: false,
      );

      // A newer remote note carries its own attachments (with driveFileIds) —
      // now authoritative, so the local column is replaced.
      final remote = const Note(
              id: 'n1', type: NoteType.note, body: 'new', createdAt: 1, updatedAt: 2)
          .copyWith(attachments: const [
        NoteAttachment(
            id: 'a2',
            name: 'g.pdf',
            fileName: 'a2.pdf',
            size: 5,
            createdAt: 2,
            driveFileId: 'drive-a2'),
      ]);
      await db.applyRemote(remote,
          driveFileId: 'file1', remoteModifiedTime: 't1');

      final merged = await db.getNote('n1');
      expect(merged!.body, 'new');
      expect(merged.attachments.single.id, 'a2');
      expect(merged.attachments.single.driveFileId, 'drive-a2');
    });

    test('upsertNote preserves an out-of-band driveFileId against a stale save',
        () async {
      // Attachment saved by the editor without a driveFileId yet.
      await db.upsertNote(
        const Note(
                id: 'n1', type: NoteType.note, body: 'b', createdAt: 1, updatedAt: 1)
            .copyWith(attachments: const [att]),
        dirty: true,
      );
      // Sync uploads the binary and records its Drive id out of band.
      await db.setAttachments('n1', const [
        NoteAttachment(
            id: 'a1',
            name: 'f.pdf',
            fileName: 'a1.pdf',
            size: 3,
            createdAt: 1,
            driveFileId: 'drive-a1'),
      ]);
      // The editor re-saves its stale snapshot (attachment still driveFileId-less).
      await db.upsertNote(
        const Note(
                id: 'n1', type: NoteType.note, body: 'edited', createdAt: 1, updatedAt: 2)
            .copyWith(attachments: const [att]),
        dirty: true,
      );

      final loaded = await db.getNote('n1');
      expect(loaded!.body, 'edited');
      // The driveFileId must survive — otherwise the binary re-uploads as a dup.
      expect(loaded.attachments.single.driveFileId, 'drive-a1');
    });
  });
}
