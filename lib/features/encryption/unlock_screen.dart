import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

/// Full-screen gate shown when encryption is enabled for the account but this
/// device doesn't hold the master key yet. Blocks all note access until the
/// correct key is entered (then it's cached and never asked again).
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(encryptionControllerProvider.notifier)
        .unlockWithKey(key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = 'That master key is incorrect.';
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _controller.text = text;
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect this device?'),
        content: const Text(
          'This stops syncing and lets you use the app without the master key. '
          'Your encrypted notes on Google Drive are left untouched — you can '
          'reconnect later with the key. Nothing is deleted from the cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // The local rows are ciphertext this device can't read; wipe them so the
    // app is usable again (the encrypted copies stay safe on Drive).
    await ref.read(databaseProvider).wipeAllContent();
    await ref.read(syncControllerProvider.notifier).signOut();
    await ref
        .read(settingsControllerProvider.notifier)
        .applyEncryptionState(false, null);
    await ref.read(settingsServiceProvider).setMasterKey(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 20),
                Text('Notes are encrypted',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'Enter your master key to unlock this device. You only need to '
                  'do this once.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _unlock(),
                  decoration: InputDecoration(
                    labelText: 'Master key',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _busy ? null : _paste,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _unlock,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : _disconnect,
                  child: const Text('Can’t access your key?'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
