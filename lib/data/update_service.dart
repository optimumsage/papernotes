import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';

/// The result of an update check against the GitHub Releases API.
class UpdateInfo {
  final bool updateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String? notes;
  final String? assetUrl; // platform-matched downloadable asset
  final String? assetName;
  final String htmlUrl; // release page (used for manual desktop updates)

  const UpdateInfo({
    required this.updateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    required this.htmlUrl,
    this.notes,
    this.assetUrl,
    this.assetName,
  });
}

class UpdateException implements Exception {
  final String message;
  UpdateException(this.message);
  @override
  String toString() => message;
}

/// Checks GitHub Releases for a newer build and, on Android, downloads and
/// launches the signed APK so the app can update itself. On desktop the
/// download asset can't safely replace a running binary, so we open the
/// release page in the browser instead.
class UpdateService {
  Uri get _latestReleaseUri => Uri.parse(
      'https://api.github.com/repos/${AppConfig.githubOwner}/${AppConfig.githubRepo}/releases/latest');

  Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<UpdateInfo> check() async {
    final current = await currentVersion();
    final res = await http.get(_latestReleaseUri,
        headers: {'Accept': 'application/vnd.github+json'});

    if (res.statusCode == 404) {
      throw UpdateException('No releases published yet.');
    }
    if (res.statusCode != 200) {
      throw UpdateException('Update check failed (${res.statusCode}).');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = (json['tag_name'] as String? ?? '').replaceFirst('v', '');
    final assets = ((json['assets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final asset = _assetForPlatform(assets);

    return UpdateInfo(
      updateAvailable: _isNewer(latest, current),
      currentVersion: current,
      latestVersion: latest,
      notes: json['body'] as String?,
      htmlUrl: json['html_url'] as String? ??
          'https://github.com/${AppConfig.githubOwner}/${AppConfig.githubRepo}/releases',
      assetUrl: asset?['browser_download_url'] as String?,
      assetName: asset?['name'] as String?,
    );
  }

  /// Applies the update. Android installs the APK directly (requires the
  /// "install unknown apps" permission); other platforms open the release page.
  Future<void> applyUpdate(UpdateInfo info,
      {void Function(double progress)? onProgress}) async {
    if (Platform.isAndroid && info.assetUrl != null) {
      final file = await _download(info.assetUrl!, info.assetName ?? 'update.apk',
          onProgress: onProgress);
      final result = await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) {
        throw UpdateException('Could not start the installer: ${result.message}');
      }
    } else {
      final uri = Uri.parse(info.assetUrl ?? info.htmlUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw UpdateException('Could not open the download page.');
      }
    }
  }

  // ---- internals ----

  Future<File> _download(String url, String name,
      {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    final req = http.Request('GET', Uri.parse(url));
    final res = await http.Client().send(req);
    if (res.statusCode != 200) {
      throw UpdateException('Download failed (${res.statusCode}).');
    }

    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
    return file;
  }

  Map<String, dynamic>? _assetForPlatform(List<Map<String, dynamic>> assets) {
    bool match(String name, String token, String ext) =>
        name.toLowerCase().contains(token) && name.toLowerCase().endsWith(ext);

    for (final a in assets) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      if (Platform.isAndroid && name.endsWith('.apk')) return a;
      if (Platform.isMacOS && match(name, 'macos', '.zip')) return a;
      if (Platform.isWindows && match(name, 'windows', '.zip')) return a;
      if (Platform.isLinux && match(name, 'linux', '.tar.gz')) return a;
    }
    return null;
  }

  /// Semantic-version "greater than" comparison of dotted numeric versions.
  bool _isNewer(String latest, String current) {
    List<int> parts(String v) => v
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final a = parts(latest), b = parts(current);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
