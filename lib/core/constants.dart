/// App-wide constants and keys.
class AppKeys {
  AppKeys._();

  // shared_preferences keys (non-secret)
  static const syncEnabled = 'sync_enabled';
  static const themeMode = 'theme_mode'; // 'system' | 'light' | 'dark'
  static const lastSyncedAt = 'last_synced_at'; // epoch ms
  static const driveClientId = 'drive_client_id'; // non-secret per OAuth norms

  // Appearance & behavior preferences (non-secret)
  static const fontScale = 'font_scale'; // double (e.g. 0.85 / 1.0 / 1.15 / 1.3)
  static const sortMode = 'sort_mode'; // SortMode.name
  static const viewStyle = 'view_style'; // ViewStyle.name
  static const defaultColor = 'default_color'; // int palette index
  static const syncOnLaunch = 'sync_on_launch'; // bool
  static const autoSyncEnabled = 'auto_sync_enabled'; // bool
  static const autoSyncMinutes = 'auto_sync_minutes'; // int
  static const confirmDelete = 'confirm_delete'; // bool
  static const trashRetentionDays = 'trash_retention_days'; // int, 0 = never
  static const previewLines = 'preview_lines'; // int 1..8, body preview lines
  static const launchAtStartup = 'launch_at_startup'; // bool, desktop only

  // SecureStore keys (encrypted secrets)
  static const driveClientSecret = 'drive_client_secret';
  static const driveRefreshToken = 'drive_refresh_token';
}

class AppConfig {
  AppConfig._();

  /// Narrow Drive scope: app can only see files it created in the hidden
  /// appDataFolder. Nothing else in the user's Drive is touched.
  static const driveScope = 'https://www.googleapis.com/auth/drive.appdata';

  /// GitHub repository used for the in-app update check / self-update.
  static const githubOwner = 'optimumsage';
  static const githubRepo = 'papernotes';

  /// Permanently-deleted (tombstoned) notes are kept this long so other devices
  /// can learn of the deletion before the row + remote file are purged.
  static const tombstoneRetention = Duration(days: 30);

  /// Debounce window for auto-save while typing.
  static const autosaveDebounce = Duration(milliseconds: 600);

  /// Defaults for newly-installed apps.
  static const defaultAutoSyncMinutes = 5;
  static const defaultTrashRetentionDays = 30;

  /// How many lines of a note's body preview a card shows in the list/grid.
  static const defaultPreviewLines = 8;
  static const minPreviewLines = 1;
  static const maxPreviewLines = 8;

  /// Selectable auto-sync intervals (minutes) and trash retention windows.
  static const autoSyncOptions = [5, 15, 30, 60];
  static const trashRetentionOptions = [7, 30, 0]; // 0 = never auto-empty
}
