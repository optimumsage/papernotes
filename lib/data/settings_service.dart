import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/note_sort.dart';
import 'local/secure_store.dart';

/// Immutable snapshot of user settings, surfaced to the UI via a provider.
class AppSettings {
  final bool syncEnabled;
  final ThemeMode themeMode;
  final int? lastSyncedAt; // epoch ms
  final String? clientId;
  final bool hasClientSecret;
  final bool signedIn;

  // Appearance & behavior
  final double fontScale;
  final SortMode sortMode;
  final ViewStyle viewStyle;
  final int defaultColor;
  final bool syncOnLaunch;
  final bool autoSyncEnabled;
  final int autoSyncMinutes;
  final bool confirmDelete;
  final int trashRetentionDays; // 0 = never auto-empty

  const AppSettings({
    this.syncEnabled = false,
    this.themeMode = ThemeMode.system,
    this.lastSyncedAt,
    this.clientId,
    this.hasClientSecret = false,
    this.signedIn = false,
    this.fontScale = 1.0,
    this.sortMode = SortMode.updated,
    this.viewStyle = ViewStyle.grid,
    this.defaultColor = 0,
    this.syncOnLaunch = true,
    this.autoSyncEnabled = true,
    this.autoSyncMinutes = AppConfig.defaultAutoSyncMinutes,
    this.confirmDelete = true,
    this.trashRetentionDays = AppConfig.defaultTrashRetentionDays,
  });

  bool get isConfigured =>
      (clientId?.isNotEmpty ?? false) && hasClientSecret;

  AppSettings copyWith({
    bool? syncEnabled,
    ThemeMode? themeMode,
    int? lastSyncedAt,
    String? clientId,
    bool? hasClientSecret,
    bool? signedIn,
    double? fontScale,
    SortMode? sortMode,
    ViewStyle? viewStyle,
    int? defaultColor,
    bool? syncOnLaunch,
    bool? autoSyncEnabled,
    int? autoSyncMinutes,
    bool? confirmDelete,
    int? trashRetentionDays,
  }) {
    return AppSettings(
      syncEnabled: syncEnabled ?? this.syncEnabled,
      themeMode: themeMode ?? this.themeMode,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      clientId: clientId ?? this.clientId,
      hasClientSecret: hasClientSecret ?? this.hasClientSecret,
      signedIn: signedIn ?? this.signedIn,
      fontScale: fontScale ?? this.fontScale,
      sortMode: sortMode ?? this.sortMode,
      viewStyle: viewStyle ?? this.viewStyle,
      defaultColor: defaultColor ?? this.defaultColor,
      syncOnLaunch: syncOnLaunch ?? this.syncOnLaunch,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      autoSyncMinutes: autoSyncMinutes ?? this.autoSyncMinutes,
      confirmDelete: confirmDelete ?? this.confirmDelete,
      trashRetentionDays: trashRetentionDays ?? this.trashRetentionDays,
    );
  }
}

/// Persists non-secret flags in shared_preferences and secrets (client secret,
/// refresh token) in an in-app AES-256-GCM encrypted store ([SecureStore]).
class SettingsService {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  // Secrets are encrypted in-app (AES-256-GCM) rather than stored in the OS
  // keychain — no entitlements, identical behavior on every platform.
  final _secure = SecureStore();

  Future<AppSettings> load() async {
    final secret = await _secure.read(AppKeys.driveClientSecret);
    final refresh = await _secure.read(AppKeys.driveRefreshToken);
    return AppSettings(
      syncEnabled: _prefs.getBool(AppKeys.syncEnabled) ?? false,
      themeMode: _parseTheme(_prefs.getString(AppKeys.themeMode)),
      lastSyncedAt: _prefs.getInt(AppKeys.lastSyncedAt),
      clientId: _prefs.getString(AppKeys.driveClientId),
      hasClientSecret: secret != null && secret.isNotEmpty,
      signedIn: refresh != null && refresh.isNotEmpty,
      fontScale: _prefs.getDouble(AppKeys.fontScale) ?? 1.0,
      sortMode: sortModeFromName(_prefs.getString(AppKeys.sortMode)),
      viewStyle: viewStyleFromName(_prefs.getString(AppKeys.viewStyle)),
      defaultColor: _prefs.getInt(AppKeys.defaultColor) ?? 0,
      syncOnLaunch: _prefs.getBool(AppKeys.syncOnLaunch) ?? true,
      autoSyncEnabled: _prefs.getBool(AppKeys.autoSyncEnabled) ?? true,
      autoSyncMinutes: _prefs.getInt(AppKeys.autoSyncMinutes) ??
          AppConfig.defaultAutoSyncMinutes,
      confirmDelete: _prefs.getBool(AppKeys.confirmDelete) ?? true,
      trashRetentionDays: _prefs.getInt(AppKeys.trashRetentionDays) ??
          AppConfig.defaultTrashRetentionDays,
    );
  }

  Future<void> setSyncEnabled(bool value) =>
      _prefs.setBool(AppKeys.syncEnabled, value);

  Future<void> setThemeMode(ThemeMode mode) =>
      _prefs.setString(AppKeys.themeMode, mode.name);

  Future<void> setFontScale(double value) =>
      _prefs.setDouble(AppKeys.fontScale, value);

  Future<void> setSortMode(SortMode mode) =>
      _prefs.setString(AppKeys.sortMode, mode.name);

  Future<void> setViewStyle(ViewStyle style) =>
      _prefs.setString(AppKeys.viewStyle, style.name);

  Future<void> setDefaultColor(int index) =>
      _prefs.setInt(AppKeys.defaultColor, index);

  Future<void> setSyncOnLaunch(bool value) =>
      _prefs.setBool(AppKeys.syncOnLaunch, value);

  Future<void> setAutoSyncEnabled(bool value) =>
      _prefs.setBool(AppKeys.autoSyncEnabled, value);

  Future<void> setAutoSyncMinutes(int value) =>
      _prefs.setInt(AppKeys.autoSyncMinutes, value);

  Future<void> setConfirmDelete(bool value) =>
      _prefs.setBool(AppKeys.confirmDelete, value);

  Future<void> setTrashRetentionDays(int value) =>
      _prefs.setInt(AppKeys.trashRetentionDays, value);

  Future<void> setLastSyncedAt(int epochMs) =>
      _prefs.setInt(AppKeys.lastSyncedAt, epochMs);

  Future<void> setClientId(String value) =>
      _prefs.setString(AppKeys.driveClientId, value);

  Future<void> setClientSecret(String value) =>
      _secure.write(AppKeys.driveClientSecret, value);

  Future<String?> readClientId() async =>
      _prefs.getString(AppKeys.driveClientId);

  Future<String?> readClientSecret() =>
      _secure.read(AppKeys.driveClientSecret);

  Future<String?> readRefreshToken() =>
      _secure.read(AppKeys.driveRefreshToken);

  Future<void> setRefreshToken(String? value) async {
    if (value == null) {
      await _secure.delete(AppKeys.driveRefreshToken);
    } else {
      await _secure.write(AppKeys.driveRefreshToken, value);
    }
  }

  ThemeMode _parseTheme(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
