import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';

/// Full-screen privacy gate shown when App Lock is enabled and the app is
/// locked. Unlocks with the PIN, or with biometrics (fingerprint / Touch ID)
/// when the user enabled that. There is deliberately no PIN-recovery escape.
class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _biometricPrompted = false;

  @override
  void initState() {
    super.initState();
    // Auto-invoke the biometric prompt once when the gate appears.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptBiometric());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _biometricEnabled =>
      ref.read(settingsControllerProvider).appLockBiometricEnabled;

  Future<void> _maybePromptBiometric() async {
    if (_biometricPrompted || !_biometricEnabled) return;
    _biometricPrompted = true;
    await _authenticateBiometric();
  }

  Future<void> _authenticateBiometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok =
        await ref.read(appLockControllerProvider.notifier).unlockWithBiometric();
    if (!mounted) return;
    // On success the gate is dismissed by the controller; nothing else to do.
    if (!ok) setState(() => _busy = false);
  }

  Future<void> _submitPin() async {
    final pin = _controller.text;
    if (pin.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref.read(appLockControllerProvider.notifier).verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      ref.read(appLockControllerProvider.notifier).unlock();
    } else {
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN.';
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final biometricEnabled = ref.watch(
      settingsControllerProvider.select((s) => s.appLockBiometricEnabled),
    );
    final biometricLabel =
        ref.read(appLockServiceProvider).biometricLabel();
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
                Text('PaperNotes is locked',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'Enter your PIN to unlock.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  autofocus: !biometricEnabled,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _busy ? null : _submitPin(),
                  decoration: InputDecoration(
                    labelText: 'PIN',
                    counterText: '',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submitPin,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock'),
                ),
                if (biometricEnabled) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _authenticateBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: Text('Use $biometricLabel'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
