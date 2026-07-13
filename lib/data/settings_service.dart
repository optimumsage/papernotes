import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/note_sort.dart';
import '../core/swipe_action.dart';
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
  final int previewLines; // body preview lines shown on a card (1..8)
  final bool ruledLines; // show paper-style lines behind note body
  final bool launchAtStartup; // desktop: open the app at login
  final SwipeAction leftSwipeAction; // Android: left-swipe note action
  final SwipeAction rightSwipeAction; // Android: right-swipe note action

  // Encryption
  final bool encryptionEnabled; // notes encrypted at rest + in Drive sync
  final String? encryptionKeyFingerprint; // detects a changed master key

  // App lock (privacy gate, independent of encryption)
  final bool appLockEnabled; // require PIN/biometric to open the app
  final bool appLockBiometricEnabled; // unlock with fingerprint / Touch ID
  final int appLockAutoLockMinutes; // 0 = until app restart

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
    this.previewLines = AppConfig.defaultPreviewLines,
    this.ruledLines = AppConfig.defaultRuledLines,
    this.launchAtStartup = false,
    this.leftSwipeAction = AppConfig.defaultLeftSwipe,
    this.rightSwipeAction = AppConfig.defaultRightSwipe,
    this.encryptionEnabled = false,
    this.encryptionKeyFingerprint,
    this.appLockEnabled = false,
    this.appLockBiometricEnabled = false,
    this.appLockAutoLockMinutes = AppConfig.defaultAutoLockMinutes,
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
    int? previewLines,
    bool? ruledLines,
    bool? launchAtStartup,
    SwipeAction? leftSwipeAction,
    SwipeAction? rightSwipeAction,
    bool? encryptionEnabled,
    String? encryptionKeyFingerprint,
    bool? appLockEnabled,
    bool? appLockBiometricEnabled,
    int? appLockAutoLockMinutes,
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
      previewLines: previewLines ?? this.previewLines,
      ruledLines: ruledLines ?? this.ruledLines,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      leftSwipeAction: leftSwipeAction ?? this.leftSwipeAction,
      rightSwipeAction: rightSwipeAction ?? this.rightSwipeAction,
      encryptionEnabled: encryptionEnabled ?? this.encryptionEnabled,
      encryptionKeyFingerprint:
          encryptionKeyFingerprint ?? this.encryptionKeyFingerprint,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockBiometricEnabled:
          appLockBiometricEnabled ?? this.appLockBiometricEnabled,
      appLockAutoLockMinutes:
          appLockAutoLockMinutes ?? this.appLockAutoLockMinutes,
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
      previewLines: _prefs.getInt(AppKeys.previewLines) ??
          AppConfig.defaultPreviewLines,
      ruledLines: _prefs.getBool(AppKeys.ruledLines) ??
          AppConfig.defaultRuledLines,
      launchAtStartup: _prefs.getBool(AppKeys.launchAtStartup) ?? false,
      leftSwipeAction: _prefs.getString(AppKeys.leftSwipeAction) == null
          ? AppConfig.defaultLeftSwipe
          : swipeActionFromName(_prefs.getString(AppKeys.leftSwipeAction)),
      rightSwipeAction: _prefs.getString(AppKeys.rightSwipeAction) == null
          ? AppConfig.defaultRightSwipe
          : swipeActionFromName(_prefs.getString(AppKeys.rightSwipeAction)),
      encryptionEnabled: _prefs.getBool(AppKeys.encryptionEnabled) ?? false,
      encryptionKeyFingerprint:
          _prefs.getString(AppKeys.encryptionKeyFingerprint),
      appLockEnabled: _prefs.getBool(AppKeys.appLockEnabled) ?? false,
      appLockBiometricEnabled:
          _prefs.getBool(AppKeys.appLockBiometricEnabled) ?? false,
      appLockAutoLockMinutes: _prefs.getInt(AppKeys.appLockAutoLockMinutes) ??
          AppConfig.defaultAutoLockMinutes,
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

  Future<void> setPreviewLines(int value) =>
      _prefs.setInt(AppKeys.previewLines, value);

  Future<void> setRuledLines(bool value) =>
      _prefs.setBool(AppKeys.ruledLines, value);

  Future<void> setLaunchAtStartup(bool value) =>
      _prefs.setBool(AppKeys.launchAtStartup, value);

  Future<void> setLeftSwipeAction(SwipeAction action) =>
      _prefs.setString(AppKeys.leftSwipeAction, action.name);

  Future<void> setRightSwipeAction(SwipeAction action) =>
      _prefs.setString(AppKeys.rightSwipeAction, action.name);

  Future<void> setLastSyncedAt(int epochMs) =>
      _prefs.setInt(AppKeys.lastSyncedAt, epochMs);

  /// Cheap read of the last-synced timestamp (no secret-store access).
  int? get lastSyncedAt => _prefs.getInt(AppKeys.lastSyncedAt);

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

  // ---- Encryption ----

  Future<void> setEncryptionEnabled(bool value) =>
      _prefs.setBool(AppKeys.encryptionEnabled, value);

  Future<void> setEncryptionKeyFingerprint(String? value) async {
    if (value == null) {
      await _prefs.remove(AppKeys.encryptionKeyFingerprint);
    } else {
      await _prefs.setString(AppKeys.encryptionKeyFingerprint, value);
    }
  }

  /// The cached master key on this device (base64), or null if never unlocked.
  Future<String?> readMasterKey() => _secure.read(AppKeys.encryptionMasterKey);

  Future<void> setMasterKey(String? value) async {
    if (value == null) {
      await _secure.delete(AppKeys.encryptionMasterKey);
    } else {
      await _secure.write(AppKeys.encryptionMasterKey, value);
    }
  }

  // ---- App lock ----

  Future<void> setAppLockEnabled(bool value) =>
      _prefs.setBool(AppKeys.appLockEnabled, value);

  Future<void> setAppLockBiometricEnabled(bool value) =>
      _prefs.setBool(AppKeys.appLockBiometricEnabled, value);

  Future<void> setAppLockAutoLockMinutes(int value) =>
      _prefs.setInt(AppKeys.appLockAutoLockMinutes, value);

  /// The stored `salt:hex` PIN hash, or null if no PIN is set. Shares the one
  /// [SecureStore] instance with the other secrets so writes never clobber.
  Future<String?> readAppLockPinHash() => _secure.read(AppKeys.appLockPinHash);

  Future<void> setAppLockPinHash(String? value) async {
    if (value == null) {
      await _secure.delete(AppKeys.appLockPinHash);
    } else {
      await _secure.write(AppKeys.appLockPinHash, value);
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
