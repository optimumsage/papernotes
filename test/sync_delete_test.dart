import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/attachments/attachment_store.dart';
import 'package:papernote/data/crypto/encryption_service.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/folder.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/repositories/note_repository.dart';
import 'package:papernote/data/settings_service.dart';
import 'package:papernote/data/sync/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_drive.dart';

/// Deletion propagation across devices — the behaviour that regressed and
/// shipped, because every prior test called `applyRemote` directly and so never
/// exercised the pull's conflict resolution.
///
/// Every test here drives two real [SyncEngine]s against one shared fake Drive,
/// which is the only setup that can catch these.
void main() {
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

  ({AppDatabase db, AttachmentStore store, SyncEngine engine, NoteRepository repo})
      device(FakeDrive drive) {
    final dir = Directory.systemTemp.createTempSync('papernote_del');
    addTearDown(() => dir.existsSync() ? dir.deleteSync(recursive: true) : null);
    final crypto = EncryptionService();
    final db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);
    final store = AttachmentStore(dir);
    return (
      db: db,
      store: store,
      engine: SyncEngine(db, drive, settings, store, crypto),
      repo: NoteRepository(db, attachmentStore: store),
    );
  }

  /// Timestamps must be realistic epoch-ms: a hand-written `deletedAt` of a few
  /// hundred lands in 1970, which is instantly past the 30-day tombstone
  /// retention and gets purged mid-test.
  final now = DateTime.now().millisecondsSinceEpoch;

  Note noteAt(String id, int updatedAt, {String body = 'hello'}) => Note(
        id: id,
        type: NoteType.note,
        body: body,
        createdAt: now,
        updatedAt: updatedAt,
      );

  /// A note is "gone" for the user once its row is absent *or* tombstoned —
  /// `getNote` deliberately still returns tombstones (the sync engine needs
  /// them), so a null check alone would miss a delete that did propagate.
  Future<bool> gone(AppDatabase db, String id) async =>
      (await db.getNote(id))?.deleted ?? true;

  /// A note that exists, synced and clean, on both devices.
  Future<void> seedShared(
      ({AppDatabase db, dynamic store, SyncEngine engine, dynamic repo}) a,
      ({AppDatabase db, dynamic store, SyncEngine engine, dynamic repo}) b,
      Note note) async {
    await a.db.upsertNote(note, dirty: true);
    await a.engine.sync();
    await b.engine.sync();
    expect(await b.db.getNote(note.id), isNotNull, reason: 'seed failed');
  }

  test('a note deleted on one device is deleted on the other', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    await a.repo.deletePermanently('n1');
    await a.engine.sync();
    await b.engine.sync();

    expect(await gone(b.db, 'n1'), isTrue,
        reason: 'the tombstone should have removed it from B');
  });

  test('a tombstone wins over a locally newer copy (clock skew)', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // A deletes. B's clock runs ahead, so B's untouched row carries a *higher*
    // updatedAt than the tombstone — the exact case that used to lose and leave
    // the note alive forever.
    await a.db.upsertNote(
      (await a.db.getNote('n1'))!
          .copyWith(deleted: true, deletedAt: now, updatedAt: now),
      dirty: true,
    );
    await a.engine.sync();
    await b.db.upsertNote(noteAt('n1', now + 999999), dirty: false);

    await b.engine.sync();

    expect(await gone(b.db, 'n1'), isTrue,
        reason: 'a delete is terminal and must beat a newer live copy');
  });

  test('a local tombstone is not resurrected by a remote live copy', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // B edits with a far-future timestamp and uploads; A deletes with an older
    // one. The delete must still win on both sides.
    await b.db.upsertNote(noteAt('n1', now + 999999, body: 'edited'), dirty: true);
    await b.engine.sync();

    await a.repo.deletePermanently('n1');
    await a.engine.sync();

    expect(await gone(a.db, 'n1'), isTrue, reason: 'A deleted it');
    expect(drive.noteJson('n1')?['deleted'], isTrue,
        reason: 'the tombstone must reach Drive, not be overwritten');

    await b.engine.sync();
    expect(await gone(b.db, 'n1'), isTrue,
        reason: 'B must accept the delete despite its newer edit');
  });

  test('a diverged pair converges in one cycle instead of re-downloading forever',
      () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // A uploads an older edit; B holds a newer one that was never pushed. B's
    // pull sees a remote it does not want — it must still record the file's
    // modifiedTime and push its own copy, or it re-downloads this file on every
    // sync for the rest of time.
    await a.db.upsertNote(noteAt('n1', now + 200, body: 'from A'), dirty: true);
    await a.engine.sync();
    await b.db.upsertNote(noteAt('n1', now + 300, body: 'from B'), dirty: false);

    await b.engine.sync();
    expect((await b.db.getNote('n1'))!.body, 'from B', reason: 'B is newer');
    expect(drive.noteJson('n1')!['body'], 'from B',
        reason: "B's copy should have been pushed");

    final row = await b.db.rawRow('n1');
    expect(row!.remoteModifiedTime, isNotNull);
    expect(row.dirty, isFalse, reason: 'converged, so nothing left to push');

    // A second cycle must be a no-op: no download, nothing changed.
    final before = drive.downloads;
    final result = await b.engine.sync();
    expect(drive.downloads, before,
        reason: 'a converged file must not be re-downloaded');
    expect(result.isEmpty, isTrue);
  });

  test('an exact timestamp tie settles instead of ping-ponging', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // Same updatedAt, different content, and B has no pending edit. Without a
    // tie-break both sides would each think they won and overwrite the other on
    // alternate syncs forever.
    await a.db.upsertNote(noteAt('n1', now + 10, body: 'from A'), dirty: true);
    await a.engine.sync();
    await b.db.upsertNote(noteAt('n1', now + 10, body: 'from B'), dirty: false);

    await b.engine.sync();
    expect((await b.db.getNote('n1'))!.body, 'from A',
        reason: 'a clean device adopts the shared copy on a tie');

    // Settled: nothing more to exchange in either direction.
    expect((await b.engine.sync()).isEmpty, isTrue);
    expect((await a.engine.sync()).isEmpty, isTrue);
  });

  test('a pending local edit survives a timestamp tie', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    await a.db.upsertNote(noteAt('n1', now + 10, body: 'from A'), dirty: true);
    await a.engine.sync();
    // B's edit is unpushed: it must not be silently discarded by the tie rule.
    await b.db.upsertNote(noteAt('n1', now + 10, body: 'from B'), dirty: true);

    await b.engine.sync();
    expect((await b.db.getNote('n1'))!.body, 'from B',
        reason: 'unpushed local work must never be dropped');
  });

  test('a note whose Drive file was purged elsewhere is dropped locally',
      () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));
    await seedShared(a, b, noteAt('n2', now));

    // Simulate A having purged n1 after the retention window: the file is gone
    // from Drive, but B never saw the tombstone and its row is clean.
    drive.files.remove(drive.idOf('n1.json'));

    await b.engine.sync();

    expect(await b.db.getNote('n1'), isNull, reason: 'purged remotely');
    expect(await b.db.getNote('n2'), isNotNull, reason: 'untouched');
  });

  test('the missing-file sweep spares an unrecognized or empty listing',
      () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // Signing into a different account: the listing is non-empty but holds none
    // of our files. Wiping the device here would be catastrophic.
    final other = FakeDrive();
    await other.create(
        'someone-else', noteAt('someone-else', now, body: 'theirs').encode());
    final bOnOther = SyncEngine(
        b.db, other, settings, b.store, EncryptionService());
    await bOnOther.sync();
    expect(await b.db.getNote('n1'), isNotNull,
        reason: 'a foreign listing must never delete local notes');

    // An empty listing (a failed or truncated fetch) must be equally inert.
    final empty = FakeDrive();
    final bOnEmpty = SyncEngine(
        b.db, empty, settings, b.store, EncryptionService());
    await bOnEmpty.sync();
    expect(await b.db.getNote('n1'), isNotNull,
        reason: 'an empty listing must never delete local notes');
  });

  test('unsynced local work is never swept', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // A brand-new note on B, not yet pushed: no driveFileId, dirty.
    await b.db.upsertNote(noteAt('fresh', now + 500), dirty: true);
    drive.files.remove(drive.idOf('n1.json'));

    await b.engine.sync();

    expect(await b.db.getNote('fresh'), isNotNull,
        reason: 'a never-synced note must survive the sweep');
  });

  test('a folder deleted on one device is deleted on the other', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);

    await a.db.upsertFolder(
      Folder(id: 'f1', name: 'Work', createdAt: now, updatedAt: now),
      dirty: true,
    );
    await a.engine.sync();
    await b.engine.sync();
    expect(await b.db.getFolder('f1'), isNotNull);

    // Delete on A with an older timestamp than B's untouched row.
    await a.db.upsertFolder(
      Folder(
          id: 'f1',
          name: 'Work',
          createdAt: now,
          updatedAt: now,
          deleted: true,
          deletedAt: now),
      dirty: true,
    );
    await a.engine.sync();
    await b.db.upsertFolder(
      Folder(id: 'f1', name: 'Work', createdAt: now, updatedAt: now + 999999),
      dirty: false,
    );

    await b.engine.sync();

    expect((await b.db.getFolder('f1'))?.deleted ?? true, isTrue,
        reason: 'the folder tombstone must win');
  });

  test('a delete is never pushed by the quick path', () async {
    final drive = FakeDrive();
    final a = device(drive);
    final b = device(drive);
    await seedShared(a, b, noteAt('n1', now));

    // B deletes n1 and syncs it away.
    await b.repo.deletePermanently('n1');
    await b.engine.sync();

    // A edits the same note offline, then fires the debounced quick sync. The
    // quick path pushes without pulling, so if it ran here it would overwrite
    // B's tombstone and resurrect the note everywhere.
    await a.db.upsertNote(noteAt('n1', now + 150, body: 'still alive'), dirty: true);
    await a.repo.deletePermanently('n1');
    await a.engine.sync(quick: true);

    expect(drive.noteJson('n1')?['deleted'], isTrue,
        reason: 'the tombstone on Drive must survive the quick push');
  });
}
