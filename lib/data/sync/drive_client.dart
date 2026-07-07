import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'drive_auth.dart';

/// An http.Client that injects a fresh Bearer token on every request. The
/// token is fetched (and refreshed if needed) by [DriveAuth] per call.
class _AuthClient extends http.BaseClient {
  _AuthClient(this._auth);
  final DriveAuth _auth;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await _auth.accessToken();
    request.headers['Authorization'] = 'Bearer $token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// A remote note file's metadata as listed from the appDataFolder.
class RemoteFile {
  final String id;
  final String name; // "<noteId>.json"
  final String? modifiedTime; // RFC3339 string from Drive

  RemoteFile(this.id, this.name, this.modifiedTime);

  String get noteId => name.endsWith('.json')
      ? name.substring(0, name.length - 5)
      : name;
}

/// The Drive operations the [SyncEngine] depends on. Extracted so the engine
/// can be driven against an in-memory fake in tests without real network/auth.
abstract interface class DriveApi {
  Future<List<RemoteFile>> list();
  Future<Map<String, dynamic>> download(String fileId);
  Future<RemoteFile> create(String noteId, String content);
  Future<RemoteFile> update(String fileId, String noteId, String content);
  Future<void> deleteFile(String fileId);
  Future<String?> modifiedTime(String fileId);
  Future<RemoteFile> createBinary(String name, List<int> bytes);
  Future<List<int>> downloadBytes(String fileId);
}

/// Thin wrapper over Drive v3 scoped to the hidden `appDataFolder`. Every note
/// is one `<noteId>.json` file; filenames are UUIDs so they never collide.
class DriveClient implements DriveApi {
  DriveClient(DriveAuth auth) : _http = _AuthClient(auth);

  final _AuthClient _http;
  drive.DriveApi get _api => drive.DriveApi(_http);

  static const _space = 'appDataFolder';

  /// Lists every note file in the app folder (handles pagination).
  @override
  Future<List<RemoteFile>> list() async {
    final files = <RemoteFile>[];
    String? pageToken;
    do {
      final res = await _api.files.list(
        spaces: _space,
        $fields: 'nextPageToken, files(id, name, modifiedTime)',
        pageSize: 1000,
        pageToken: pageToken,
      );
      for (final f in res.files ?? const <drive.File>[]) {
        if (f.id != null && f.name != null) {
          files.add(RemoteFile(f.id!, f.name!, f.modifiedTime?.toIso8601String()));
        }
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null);
    return files;
  }

  /// Downloads and decodes the JSON body of a file.
  @override
  Future<Map<String, dynamic>> download(String fileId) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      bytes.add(chunk);
    }
    return (jsonDecode(utf8.decode(bytes.takeBytes())) as Map)
        .cast<String, dynamic>();
  }

  /// Creates a new file in the app folder. Returns (fileId, modifiedTime).
  @override
  Future<RemoteFile> create(String noteId, String content) async {
    final metadata = drive.File()
      ..name = '$noteId.json'
      ..parents = [_space];
    final created = await _api.files.create(
      metadata,
      uploadMedia: _media(content),
      $fields: 'id, name, modifiedTime',
    );
    return RemoteFile(
        created.id!, created.name!, created.modifiedTime?.toIso8601String());
  }

  /// Overwrites an existing file's content. Returns the new modifiedTime.
  @override
  Future<RemoteFile> update(String fileId, String noteId, String content) async {
    final updated = await _api.files.update(
      drive.File(),
      fileId,
      uploadMedia: _media(content),
      $fields: 'id, name, modifiedTime',
    );
    return RemoteFile(
        updated.id!, '$noteId.json', updated.modifiedTime?.toIso8601String());
  }

  /// Uploads a raw binary (an attachment) to the app folder under [name].
  /// Returns its Drive file id + modifiedTime.
  @override
  Future<RemoteFile> createBinary(String name, List<int> bytes) async {
    final metadata = drive.File()
      ..name = name
      ..parents = [_space];
    final media = drive.Media(Stream.value(bytes), bytes.length,
        contentType: 'application/octet-stream');
    final created = await _api.files.create(
      metadata,
      uploadMedia: media,
      $fields: 'id, name, modifiedTime',
    );
    return RemoteFile(
        created.id!, created.name!, created.modifiedTime?.toIso8601String());
  }

  /// Downloads a file's raw bytes (an attachment binary).
  @override
  Future<List<int>> downloadBytes(String fileId) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> deleteFile(String fileId) => _api.files.delete(fileId);

  /// Fetches just a file's current modifiedTime (one cheap metadata GET, no
  /// content). Returns null when the file no longer exists remotely.
  @override
  Future<String?> modifiedTime(String fileId) async {
    try {
      final file =
          await _api.files.get(fileId, $fields: 'modifiedTime') as drive.File;
      return file.modifiedTime?.toIso8601String();
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  drive.Media _media(String content) {
    final bytes = utf8.encode(content);
    return drive.Media(Stream.value(bytes), bytes.length,
        contentType: 'application/json');
  }

  void close() => _http.close();
}
