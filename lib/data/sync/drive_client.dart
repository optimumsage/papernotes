import 'dart:convert';

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

/// Thin wrapper over Drive v3 scoped to the hidden `appDataFolder`. Every note
/// is one `<noteId>.json` file; filenames are UUIDs so they never collide.
class DriveClient {
  DriveClient(DriveAuth auth) : _http = _AuthClient(auth);

  final _AuthClient _http;
  drive.DriveApi get _api => drive.DriveApi(_http);

  static const _space = 'appDataFolder';

  /// Lists every note file in the app folder (handles pagination).
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
  Future<Map<String, dynamic>> download(String fileId) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
  }

  /// Creates a new file in the app folder. Returns (fileId, modifiedTime).
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

  Future<void> deleteFile(String fileId) => _api.files.delete(fileId);

  drive.Media _media(String content) {
    final bytes = utf8.encode(content);
    return drive.Media(Stream.value(bytes), bytes.length,
        contentType: 'application/json');
  }

  void close() => _http.close();
}
