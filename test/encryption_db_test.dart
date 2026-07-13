import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/crypto/encryption_service.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/checklist_item.dart';
import 'package:papernote/data/models/folder.dart';
import 'package:papernote/data/models/note.dart';

void main() {
  test('migrateEncryption encrypts existing plaintext rows at rest', () async {
    final crypto = EncryptionService();
    final db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);

    await db.upsertNote(
      const Note(
          id: 'n1', type: NoteType.note, body: 'secret', createdAt: 1, updatedAt: 1),
      dirty: false,
    );

    final key = EncryptionService.generateMasterKey();
    await db.migrateEncryption(() => crypto.unlock(key));

    // The row on disk is now ciphertext, but the model reads back in the clear.
    final raw = (await db.allRawRows()).single;
    expect(raw.body, startsWith(EncryptionService.sentinel));
    expect(raw.dirty, isTrue, reason: 'migrated rows re-sync');
    expect((await db.getNote('n1'))!.body, 'secret');
  });

  test('migrateEncryption rotates rows from an old key to a new key', () async {
    final crypto = EncryptionService();
    final db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);

    final k1 = EncryptionService.generateMasterKey();
    final k2 = EncryptionService.generateMasterKey();

    await db.upsertNote(
      const Note(
          id: 'n1', type: NoteType.note, body: 'secret', createdAt: 1, updatedAt: 1),
      dirty: false,
    );
    await db.migrateEncryption(() => crypto.unlock(k1)); // enable under k1

    // Rotate: crypto is unlocked with k1 (so reads decrypt), migrate to k2.
    await db.migrateEncryption(() => crypto.unlock(k2));

    expect((await db.getNote('n1'))!.body, 'secret');
    final stored = (await db.allRawRows()).single.body!;
    // Stored row now decrypts with the new key only.
    expect(EncryptionService.tryDecryptWith(k2, stored), 'secret');
    expect(EncryptionService.tryDecryptWith(k1, stored), isNot('secret'));
  });

  test('a locked device reads encrypted checklist rows without crashing',
      () async {
    final key = EncryptionService.generateMasterKey();
    final crypto = EncryptionService()..unlock(key);
    final db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);

    await db.upsertNote(
      Note(
        id: 'c1',
        type: NoteType.checklist,
        createdAt: 1,
        updatedAt: 1,
        items: [ChecklistItem(id: 'i1', text: 'buy milk', checked: false)],
      ),
      dirty: false,
    );

    // Lock (as if the app relaunched without the key) and read: the ciphertext
    // items column must degrade to empty rather than throw a FormatException
    // through the notes stream.
    crypto.lock();
    final note = await db.getNote('c1');
    expect(note, isNotNull);
    expect(note!.items, isEmpty);
    expect(note.title, isNull);
  });

  test('folder names are encrypted at rest and read back', () async {
    final crypto = EncryptionService()
      ..unlock(EncryptionService.generateMasterKey());
    final db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);

    await db.upsertFolder(
      const Folder(id: 'f1', name: 'Private', createdAt: 1, updatedAt: 1),
      dirty: false,
    );
    final raw = (await db.allRawFolderRows()).single;
    expect(raw.name, startsWith(EncryptionService.sentinel));
    expect((await db.getFolder('f1'))!.name, 'Private');
  });
}
