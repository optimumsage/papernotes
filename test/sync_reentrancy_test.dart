import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/attachments/attachment_store.dart';
import 'package:papernote/data/crypto/encryption_service.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/settings_service.dart';
import 'package:papernote/data/sync/drive_client.dart';
import 'package:papernote/data/sync/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_drive.dart';

/// A Drive whose next `list()` blocks until released (or fails), to hold a
/// sync cycle open while a second one is requested.
class _GatedDrive extends FakeDrive {
  Completer<void>? gate;
  bool failNextList = false;

  @override
  Future<List<RemoteFile>> list() async {
    final g = gate;
    if (g != null) await g.future;
    if (failNextList) {
      failNextList = false;
      throw TimeoutException('stalled');
    }
    return super.list();
  }
}

/// Overlapping syncs used to return an empty result instantly ("Up to date")
/// while the first was still running — and if that first one hung, forever.
void main() {
  late AppDatabase db;
  late SyncEngine engine;
  late _GatedDrive drive;
  final now = DateTime.now().millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService(await SharedPreferences.getInstance());
    final dir = Directory.systemTemp.createTempSync('papernote_reent');
    addTearDown(() => dir.existsSync() ? dir.deleteSync(recursive: true) : null);
    final crypto = EncryptionService();
    db = AppDatabase.forTesting(NativeDatabase.memory(), crypto: crypto);
    addTearDown(db.close);
    drive = _GatedDrive();
    engine = SyncEngine(db, drive, settings, AttachmentStore(dir), crypto);
  });

  Note note(String id) => Note(
      id: id, type: NoteType.note, body: 'b', createdAt: now, updatedAt: now);

  test('a concurrent sync joins the running one instead of faking success',
      () async {
    await db.upsertNote(note('n1'), dirty: true);
    drive.gate = Completer<void>();

    final first = engine.sync();
    final second = engine.sync();
    drive.gate!.complete();

    expect((await first).pushed, 1);
    expect((await second).pushed, 1, reason: 'joined the real result');
    expect(drive.noteJson('n1'), isNotNull);
  });

  test('a failed sync releases the guard for the next one', () async {
    await db.upsertNote(note('n1'), dirty: true);
    drive.failNextList = true;
    await expectLater(engine.sync(), throwsA(isA<TimeoutException>()));

    final result = await engine.sync();
    expect(result.pushed, 1);
    expect((await db.rawRow('n1'))!.dirty, isFalse);
  });

  test('a full sync requested during a quick one runs a full cycle after it',
      () async {
    // A remote-only note that only a full (pulling) sync can bring down.
    await drive.create('remote', note('remote').encode());
    drive.gate = Completer<void>();
    // Quick with nothing dirty-and-known falls through to a full listing, so
    // it blocks on the gate too; the joiner must still get a full cycle.
    final quick = engine.sync(quick: true);
    final full = engine.sync();
    drive.gate!.complete();
    await quick;
    await full;
    expect(await db.getNote('remote'), isNotNull);
  });
}
