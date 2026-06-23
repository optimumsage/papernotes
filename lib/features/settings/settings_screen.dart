import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_snackbar.dart';
import '../../core/constants.dart';
import '../../core/note_colors.dart';
import '../../core/platform.dart';
import '../../core/swipe_action.dart';
import '../../data/update_service.dart';
import '../../providers/providers.dart';
import '../editor/color_picker.dart';

/// Named font-size steps mapped to text scale factors.
const _fontSteps = <String, double>{
  'Small': 0.85,
  'Default': 1.0,
  'Large': 1.15,
  'Larger': 1.3,
};

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _clientIdController = TextEditingController();
  final _clientSecretController = TextEditingController();
  bool _obscureSecret = true;
  String? _version;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _clientIdController.text =
        ref.read(settingsControllerProvider).clientId ?? '';
    ref.read(updateServiceProvider).currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  /// Saves the credentials. Returns false (and surfaces a message) on failure
  /// instead of letting the exception escape and crash the action.
  Future<bool> _saveCredentials({bool announce = true}) async {
    try {
      await ref.read(settingsControllerProvider.notifier).setCredentials(
            _clientIdController.text,
            _clientSecretController.text,
          );
      _clientSecretController.clear();
      if (announce) _snack('Credentials saved');
      return true;
    } catch (e) {
      _snack('Could not save credentials: $e');
      return false;
    }
  }

  Future<void> _signIn() async {
    if (!await _saveCredentials(announce: false)) return;
    await ref.read(syncControllerProvider.notifier).signInAndEnable();
    final status = ref.read(syncControllerProvider);
    if (status.phase == SyncPhase.error) {
      _snack(status.message ?? 'Sign-in failed');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message);
  }

  Future<void> _checkForUpdates() async {
    setState(() => _checkingUpdate = true);
    try {
      final info = await ref.read(updateServiceProvider).check();
      if (!mounted) return;
      if (info.updateAvailable) {
        _showUpdateDialog(info);
      } else {
        _snack('You\'re on the latest version (${info.currentVersion}).');
      }
    } on UpdateException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Update check failed: $e');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update to ${info.latestVersion}'),
        content: SingleChildScrollView(
          child: Text(
            (info.notes == null || info.notes!.trim().isEmpty)
                ? 'A new version is available (you have ${info.currentVersion}).'
                : info.notes!.trim(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _runUpdate(info);
            },
            child: const Text('Update now'),
          ),
        ],
      ),
    );
  }

  Future<void> _runUpdate(UpdateInfo info) async {
    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Downloading update'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value == 0 ? null : value),
              const SizedBox(height: 12),
              Text(value == 0 ? 'Starting…' : '${(value * 100).round()}%'),
            ],
          ),
        ),
      ),
    );
    try {
      await ref
          .read(updateServiceProvider)
          .applyUpdate(info, onProgress: (p) => progress.value = p);
      if (mounted) Navigator.of(context).pop(); // close progress
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _snack('Update failed: $e');
    } finally {
      progress.dispose();
    }
  }

  Future<void> _emptyTrash() async {
    final settings = ref.read(settingsControllerProvider);
    if (settings.confirmDelete) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Empty trash?'),
          content: const Text(
              'All notes in Trash will be permanently deleted. This cannot be undone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Empty trash')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(noteRepositoryProvider).emptyTrash();
    _snack('Trash emptied');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final sync = ref.watch(syncControllerProvider);
    final ctrl = ref.read(settingsControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // ---- Appearance ----
          _sectionLabel(context, 'Appearance'),
          Card(
            child: RadioGroup<ThemeMode>(
              groupValue: settings.themeMode,
              onChanged: (m) => m == null ? null : ctrl.setThemeMode(m),
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                      title: Text('System'), value: ThemeMode.system),
                  RadioListTile<ThemeMode>(
                      title: Text('Light'), value: ThemeMode.light),
                  RadioListTile<ThemeMode>(
                      title: Text('Dark'), value: ThemeMode.dark),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Font size', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in _fontSteps.entries)
                        ChoiceChip(
                          label: Text(entry.key),
                          selected:
                              (settings.fontScale - entry.value).abs() < 0.001,
                          onSelected: (_) => ctrl.setFontScale(entry.value),
                        ),
                    ],
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Default note color'),
                    subtitle: Text(NoteColors.nameOf(settings.defaultColor)),
                    trailing: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: NoteColors.background(
                            settings.defaultColor, theme.brightness),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: theme.colorScheme.outlineVariant),
                      ),
                    ),
                    onTap: () => ColorPickerSheet.show(
                      context,
                      selected: settings.defaultColor,
                      onPick: ctrl.setDefaultColor,
                    ),
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Card preview lines'),
                    subtitle:
                        const Text('Lines of a note shown on each card'),
                    trailing: DropdownButton<int>(
                      value: settings.previewLines,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (var n = AppConfig.minPreviewLines;
                            n <= AppConfig.maxPreviewLines;
                            n++)
                          DropdownMenuItem(value: n, child: Text('$n')),
                      ],
                      onChanged: (v) =>
                          v == null ? null : ctrl.setPreviewLines(v),
                    ),
                  ),
                  const Divider(height: 28),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Ruled lines'),
                    subtitle:
                        const Text('Show paper-style lines behind notes'),
                    value: settings.ruledLines,
                    onChanged: ctrl.setRuledLines,
                  ),
                ],
              ),
            ),
          ),

          // ---- Swipe actions (Android only) ----
          if (isAndroidPlatform) ...[
            const SizedBox(height: 16),
            _sectionLabel(context, 'Swipe actions'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.swipe_right_alt_outlined),
                    title: const Text('Swipe right'),
                    subtitle: const Text('Action when you swipe a note right'),
                    trailing: _swipeDropdown(
                      settings.rightSwipeAction,
                      ctrl.setRightSwipeAction,
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.swipe_left_alt_outlined),
                    title: const Text('Swipe left'),
                    subtitle: const Text('Action when you swipe a note left'),
                    trailing: _swipeDropdown(
                      settings.leftSwipeAction,
                      ctrl.setLeftSwipeAction,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ---- Sync ----
          const SizedBox(height: 16),
          _sectionLabel(context, 'Google Drive sync'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    settings.signedIn
                        ? 'Signed in. Notes sync across your devices via your private Drive app folder.'
                        : 'Paste your Google OAuth client ID and secret, then sign in. With sync off, notes stay only on this device.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _clientIdController,
                    decoration: const InputDecoration(
                      labelText: 'Client ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _clientSecretController,
                    obscureText: _obscureSecret,
                    decoration: InputDecoration(
                      labelText: settings.hasClientSecret
                          ? 'Client secret (saved — type to replace)'
                          : 'Client secret',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: Icon(_obscureSecret
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () =>
                            setState(() => _obscureSecret = !_obscureSecret),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!settings.signedIn)
                    FilledButton.icon(
                      onPressed:
                          sync.phase == SyncPhase.running ? null : _signIn,
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in & enable sync'),
                    )
                  else
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: sync.phase == SyncPhase.running
                              ? null
                              : () => ref
                                  .read(syncControllerProvider.notifier)
                                  .syncNow(),
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () => ref
                              .read(syncControllerProvider.notifier)
                              .signOut(),
                          icon: const Icon(Icons.logout),
                          label: const Text('Sign out'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  _syncStatusLine(context, settings, sync),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Sync on launch'),
                  subtitle: const Text('Pull changes when the app opens'),
                  value: settings.syncOnLaunch,
                  onChanged: ctrl.setSyncOnLaunch,
                ),
                SwitchListTile(
                  title: const Text('Background auto-sync'),
                  subtitle: Text(settings.autoSyncEnabled
                      ? 'Every ${settings.autoSyncMinutes} min'
                      : 'Off'),
                  value: settings.autoSyncEnabled,
                  onChanged: ctrl.setAutoSyncEnabled,
                ),
                if (settings.autoSyncEnabled)
                  ListTile(
                    title: const Text('Auto-sync interval'),
                    trailing: DropdownButton<int>(
                      value: settings.autoSyncMinutes,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final m in _intervalOptions(settings.autoSyncMinutes))
                          DropdownMenuItem(value: m, child: Text('$m min')),
                      ],
                      onChanged: (v) =>
                          v == null ? null : ctrl.setAutoSyncMinutes(v),
                    ),
                  ),
              ],
            ),
          ),

          // ---- Notes & Trash ----
          const SizedBox(height: 16),
          _sectionLabel(context, 'Notes & Trash'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Confirm before deleting'),
                  subtitle:
                      const Text('Ask before permanently deleting from Trash'),
                  value: settings.confirmDelete,
                  onChanged: ctrl.setConfirmDelete,
                ),
                ListTile(
                  title: const Text('Auto-empty trash'),
                  subtitle: const Text('Permanently delete old trashed notes'),
                  trailing: DropdownButton<int>(
                    value: settings.trashRetentionDays,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 7, child: Text('After 7 days')),
                      DropdownMenuItem(value: 30, child: Text('After 30 days')),
                      DropdownMenuItem(value: 0, child: Text('Never')),
                    ],
                    onChanged: (v) =>
                        v == null ? null : ctrl.setTrashRetentionDays(v),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.delete_forever_outlined,
                      color: theme.colorScheme.error),
                  title: Text('Empty trash now',
                      style: TextStyle(color: theme.colorScheme.error)),
                  onTap: _emptyTrash,
                ),
              ],
            ),
          ),

          // ---- Desktop ----
          if (isDesktopPlatform) ...[
            const SizedBox(height: 16),
            _sectionLabel(context, 'Desktop'),
            Card(
              child: SwitchListTile(
                title: const Text('Launch at startup'),
                subtitle: const Text(
                    'Open PaperNotes automatically when you sign in'),
                value: settings.launchAtStartup,
                onChanged: ctrl.setLaunchAtStartup,
              ),
            ),
          ],

          // ---- About ----
          const SizedBox(height: 16),
          _sectionLabel(context, 'About'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Version'),
                  subtitle: Text(_version == null ? '…' : 'PaperNotes $_version'),
                ),
                ListTile(
                  leading: _checkingUpdate
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_alt),
                  title: const Text('Check for updates'),
                  subtitle: const Text('Download the latest release from GitHub'),
                  onTap: _checkingUpdate ? null : _checkForUpdates,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _swipeDropdown(
      SwipeAction value, void Function(SwipeAction) onChanged) {
    return DropdownButton<SwipeAction>(
      value: value,
      underline: const SizedBox.shrink(),
      items: [
        for (final a in SwipeAction.values)
          DropdownMenuItem(value: a, child: Text(a.label)),
      ],
      onChanged: (a) => a == null ? null : onChanged(a),
    );
  }

  /// Ensures the current value is present even if it isn't one of the presets.
  List<int> _intervalOptions(int current) {
    final opts = {5, 15, 30, 60, current}.toList()..sort();
    return opts;
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                )),
      );

  Widget _syncStatusLine(BuildContext context, settings, SyncStatus sync) {
    final theme = Theme.of(context);
    String text;
    Color color = theme.colorScheme.outline;
    switch (sync.phase) {
      case SyncPhase.running:
        text = sync.message ?? 'Syncing…';
      case SyncPhase.error:
        text = sync.message ?? 'Sync error';
        color = theme.colorScheme.error;
      default:
        if (settings.lastSyncedAt != null) {
          final dt = DateTime.fromMillisecondsSinceEpoch(settings.lastSyncedAt);
          text = 'Last synced ${_friendly(dt)}';
        } else {
          text = 'Not synced yet';
        }
    }
    return Row(
      children: [
        if (sync.phase == SyncPhase.running)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (sync.phase == SyncPhase.running) const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ),
      ],
    );
  }

  String _friendly(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
