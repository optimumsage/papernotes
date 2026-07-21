import 'dart:convert';

import 'package:papernote/data/sync/drive_client.dart';

/// In-memory stand-in for Drive's appDataFolder, shared by the sync tests.
class FakeDrive implements DriveApi {
  final Map<String, FakeFile> files = {};
  int _seq = 0;
  String _newId() => 'file-${_seq++}';

  /// Monotonic, distinct RFC3339 stamps. Real Drive resolves modifiedTime
  /// finely enough that two writes differ; `DateTime.now()` inside a test can
  /// repeat, which would make an unchanged-file check pass by accident.
  String _stamp() => DateTime.now()
      .toUtc()
      .add(Duration(microseconds: _seq++))
      .toIso8601String();

  /// Counts every call, so tests can assert a converged sync stops
  /// re-downloading the same file each cycle.
  int downloads = 0;

  @override
  Future<List<RemoteFile>> list() async => files.entries
      .map((e) => RemoteFile(e.key, e.value.name, e.value.modified))
      .toList();

  @override
  Future<Map<String, dynamic>> download(String fileId) async {
    downloads++;
    return (jsonDecode(utf8.decode(files[fileId]!.bytes)) as Map)
        .cast<String, dynamic>();
  }

  @override
  Future<RemoteFile> create(String noteId, String content) async {
    final id = _newId();
    files[id] = FakeFile('$noteId.json', utf8.encode(content), _stamp());
    return RemoteFile(id, '$noteId.json', files[id]!.modified);
  }

  @override
  Future<RemoteFile> update(String fileId, String noteId, String content) async {
    files[fileId] = FakeFile('$noteId.json', utf8.encode(content), _stamp());
    return RemoteFile(fileId, '$noteId.json', files[fileId]!.modified);
  }

  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);

  @override
  Future<String?> modifiedTime(String fileId) async => files[fileId]?.modified;

  @override
  Future<RemoteFile> createBinary(String name, List<int> bytes) async {
    final id = _newId();
    files[id] = FakeFile(name, bytes, _stamp());
    return RemoteFile(id, name, files[id]!.modified);
  }

  @override
  Future<void> updateBinary(String fileId, List<int> bytes) async {
    files[fileId] = FakeFile(files[fileId]!.name, bytes, _stamp());
  }

  @override
  Future<List<int>> downloadBytes(String fileId) async => files[fileId]!.bytes;

  int get attachmentCount =>
      files.values.where((f) => f.name.startsWith('attach-')).length;

  /// The stored payload for a note id, decoded — null once it's really gone.
  Map<String, dynamic>? noteJson(String noteId) {
    for (final f in files.values) {
      if (f.name == '$noteId.json') {
        return (jsonDecode(utf8.decode(f.bytes)) as Map).cast<String, dynamic>();
      }
    }
    return null;
  }

  /// The Drive file id holding [name], or null.
  String? idOf(String name) {
    for (final e in files.entries) {
      if (e.value.name == name) return e.key;
    }
    return null;
  }
}

class FakeFile {
  String name;
  List<int> bytes;
  String modified;
  FakeFile(this.name, this.bytes, this.modified);
}
