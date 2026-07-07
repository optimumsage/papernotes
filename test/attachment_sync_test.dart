import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/attachments/attachment_store.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/settings_service.dart';
import 'package:papernote/data/sync/drive_client.dart';
import 'package:papernote/data/sync/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory stand-in for Drive's appDataFolder.
class _FakeDrive implements DriveApi {
  final Map<String, _FakeFile> files = {};
  int _seq = 0;
  String _newId() => 'file-${_seq++}';
  String _stamp() => DateTime.now().toUtc().toIso8601String();

  @override
  Future<List<RemoteFile>> list() async => files.entries
      .map((e) => RemoteFile(e.key, e.value.name, e.value.modified))
      .toList();

  @override
  Future<Map<String, dynamic>> download(String fileId) async =>
      (jsonDecode(utf8.decode(files[fileId]!.bytes)) as Map)
          .cast<String, dynamic>();

  @override
  Future<RemoteFile> create(String noteId, String content) async {
    final id = _newId();
    files[id] = _FakeFile('$noteId.json', utf8.encode(content), _stamp());
    return RemoteFile(id, '$noteId.json', files[id]!.modified);
  }

  @override
  Future<RemoteFile> update(String fileId, String noteId, String content) async {
    files[fileId] = _FakeFile('$noteId.json', utf8.encode(content), _stamp());
    return RemoteFile(fileId, '$noteId.json', files[fileId]!.modified);
  }

  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);

  @override
  Future<String?> modifiedTime(String fileId) async => files[fileId]?.modified;

  @override
  Future<RemoteFile> createBinary(String name, List<int> bytes) async {
    final id = _newId();
    files[id] = _FakeFile(name, bytes, _stamp());
    return RemoteFile(id, name, files[id]!.modified);
  }

  @override
  Future<List<int>> downloadBytes(String fileId) async => files[fileId]!.bytes;

  int get attachmentCount =>
      files.values.where((f) => f.name.startsWith('attach-')).length;
}

class _FakeFile {
  String name;
  List<int> bytes;
  String modified;
  _FakeFile(this.name, this.bytes, this.modified);
}

void main() {
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

  /// Build an isolated "device": its own db, attachment store, and engine, all
  /// wired to the shared [drive].
  ({AppDatabase db, AttachmentStore store, SyncEngine engine}) device(
      _FakeDrive drive) {
    final dir = Directory.systemTemp.createTempSync('papernote_sync');
    addTearDown(() => dir.existsSync() ? dir.deleteSync(recursive: true) : null);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = AttachmentStore(dir);
    return (db: db, store: store, engine: SyncEngine(db, drive, settings, store));
  }

  test('an attachment created on one device syncs to another', () async {
    final drive = _FakeDrive();
    final a = device(drive);
    final b = device(drive);

    // Device A: a note with a real attachment binary on disk.
    final src = File('${a.store.dirFor('_tmp').parent.path}/src.txt')
      ..writeAsStringSync('hello attach');
    final att = await a.store.import('note1', src.path);
    await a.db.upsertNote(
      const Note(
              id: 'note1', type: NoteType.note, body: 'hi', createdAt: 1, updatedAt: 1)
          .copyWith(attachments: [att]),
      dirty: true,
    );

    await a.engine.sync();

    // A recorded the uploaded binary's Drive id, and Drive holds the binary.
    final aNote = await a.db.getNote('note1');
    expect(aNote!.attachments.single.driveFileId, isNotNull);
    expect(drive.attachmentCount, 1);

    // Device B pulls the note and downloads the binary.
    await b.engine.sync();

    final bNote = await b.db.getNote('note1');
    expect(bNote!.attachments.single.id, att.id);
    expect(bNote.attachments.single.name, 'src.txt');
    expect(await b.store.exists('note1', bNote.attachments.single), isTrue);
    expect(
      b.store.fileFor('note1', bNote.attachments.single).readAsStringSync(),
      'hello attach',
    );
  });

  test('a no-longer-referenced attachment binary is garbage-collected',
      () async {
    final drive = _FakeDrive();
    final a = device(drive);

    final src = File('${a.store.dirFor('_tmp').parent.path}/src.txt')
      ..writeAsStringSync('data');
    final att = await a.store.import('note1', src.path);
    await a.db.upsertNote(
      const Note(
              id: 'note1', type: NoteType.note, body: 'hi', createdAt: 1, updatedAt: 1)
          .copyWith(attachments: [att]),
      dirty: true,
    );
    await a.engine.sync();
    expect(drive.attachmentCount, 1);

    // Remove the attachment from the note, and backdate the orphaned binary
    // past the GC safety window so it becomes eligible.
    await a.db.upsertNote(
      const Note(
          id: 'note1', type: NoteType.note, body: 'hi', createdAt: 1, updatedAt: 2),
      dirty: true,
    );
    for (final f in drive.files.values) {
      if (f.name.startsWith('attach-')) {
        f.modified =
            DateTime.now().toUtc().subtract(const Duration(days: 1)).toIso8601String();
      }
    }

    await a.engine.sync();

    expect(drive.attachmentCount, 0, reason: 'orphaned binary should be swept');
  });
}
