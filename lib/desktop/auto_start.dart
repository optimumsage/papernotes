import 'dart:io';

import 'package:flutter/foundation.dart';

/// "Launch at login" for desktop, implemented with plain `dart:io` rather than a
/// plugin — the obvious package (`launch_at_startup`) pins an old `win32`
/// that clashes with `share_plus`/`package_info_plus`. Each OS gets its native
/// autostart mechanism; every call is best-effort and never throws.
///
/// - **Windows**: a shortcut in the user's Startup folder (created via
///   PowerShell's WScript.Shell so there's no console flash on login).
/// - **macOS**: a System Events login item.
/// - **Linux**: a `~/.config/autostart/*.desktop` entry.
class AutoStartService {
  AutoStartService._();

  static final AutoStartService instance = AutoStartService._();

  static const _appName = 'PaperNotes';

  String get _exe => Platform.resolvedExecutable;

  /// Whether the OS autostart entry currently exists.
  Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) return _winShortcut().existsSync();
      if (Platform.isLinux) return _linuxDesktopFile().existsSync();
      if (Platform.isMacOS) {
        final r = await Process.run('osascript', [
          '-e',
          'tell application "System Events" to get the name of every login item',
        ]);
        return r.stdout.toString().contains(_appName);
      }
    } catch (e) {
      debugPrint('AutoStart.isEnabled failed: $e');
    }
    return false;
  }

  /// Create or remove the OS autostart entry.
  Future<void> setEnabled(bool value) async {
    try {
      if (Platform.isWindows) {
        value ? await _winEnable() : _winDisable();
      } else if (Platform.isMacOS) {
        await _macDisable(); // clear any stale entry first
        if (value) await _macEnable();
      } else if (Platform.isLinux) {
        value ? _linuxEnable() : _linuxDisable();
      }
    } catch (e) {
      debugPrint('AutoStart.setEnabled($value) failed: $e');
    }
  }

  // ---- Windows ----

  File _winShortcut() {
    final appData = Platform.environment['APPDATA'] ?? '';
    return File('$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup'
        '\\$_appName.lnk');
  }

  Future<void> _winEnable() async {
    final lnk = _winShortcut();
    lnk.parent.createSync(recursive: true);
    final dir = File(_exe).parent.path;
    final ps = "\$s = (New-Object -ComObject WScript.Shell)"
        ".CreateShortcut('${lnk.path}'); \$s.TargetPath = '$_exe'; "
        "\$s.WorkingDirectory = '$dir'; \$s.Save()";
    await Process.run('powershell', ['-NoProfile', '-Command', ps]);
  }

  void _winDisable() {
    final f = _winShortcut();
    if (f.existsSync()) f.deleteSync();
  }

  // ---- macOS ----

  /// `resolvedExecutable` is .../PaperNotes.app/Contents/MacOS/PaperNotes —
  /// the login item wants the .app bundle path.
  String _macAppPath() {
    const marker = '.app/';
    final idx = _exe.indexOf(marker);
    return idx == -1 ? _exe : _exe.substring(0, idx + marker.length - 1);
  }

  Future<void> _macEnable() async {
    await Process.run('osascript', [
      '-e',
      'tell application "System Events" to make login item at end '
          'with properties {path:"${_macAppPath()}", hidden:false, '
          'name:"$_appName"}',
    ]);
  }

  Future<void> _macDisable() async {
    await Process.run('osascript', [
      '-e',
      'tell application "System Events" to delete login item "$_appName"',
    ]);
  }

  // ---- Linux ----

  File _linuxDesktopFile() {
    final home = Platform.environment['HOME'] ?? '';
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return File('$base/autostart/papernotes.desktop');
  }

  void _linuxEnable() {
    final f = _linuxDesktopFile();
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('[Desktop Entry]\n'
        'Type=Application\n'
        'Name=$_appName\n'
        'Exec="$_exe"\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n');
  }

  void _linuxDisable() {
    final f = _linuxDesktopFile();
    if (f.existsSync()) f.deleteSync();
  }
}
