import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _minPinLength = 4;
const _maxPinLength = 8;

/// Prompt the user to choose (and confirm) a numeric PIN. Returns the chosen
/// PIN, or null if cancelled. Shows a clear "cannot be recovered" warning since
/// there is no PIN recovery.
Future<String?> showSetPinDialog(BuildContext context, {String? title}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SetPinDialog(title: title ?? 'Set a PIN'),
  );
}

/// Prompt for the current PIN and validate it via [verify]. Returns true once
/// the correct PIN is entered, false/null if cancelled.
Future<bool> showVerifyPinDialog(
  BuildContext context, {
  required Future<bool> Function(String pin) verify,
  String? title,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _VerifyPinDialog(
      title: title ?? 'Enter your PIN',
      verify: verify,
    ),
  );
  return ok ?? false;
}

TextField _pinField({
  required TextEditingController controller,
  required String label,
  String? errorText,
  bool autofocus = false,
  VoidCallback? onSubmitted,
}) {
  return TextField(
    controller: controller,
    autofocus: autofocus,
    keyboardType: TextInputType.number,
    obscureText: true,
    maxLength: _maxPinLength,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(
      labelText: label,
      counterText: '',
      errorText: errorText,
      border: const OutlineInputBorder(),
    ),
    onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
  );
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog({required this.title});
  final String title;

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pin.text;
    if (pin.length < _minPinLength) {
      setState(() => _error = 'Use at least $_minPinLength digits.');
      return;
    }
    if (pin != _confirm.text) {
      setState(() => _error = 'PINs don\'t match.');
      return;
    }
    Navigator.pop(context, pin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pinField(
            controller: _pin,
            label: 'PIN ($_minPinLength–$_maxPinLength digits)',
            autofocus: true,
          ),
          const SizedBox(height: 12),
          _pinField(
            controller: _confirm,
            label: 'Confirm PIN',
            errorText: _error,
            onSubmitted: _submit,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'There is no way to recover a forgotten PIN — keep it safe.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _VerifyPinDialog extends StatefulWidget {
  const _VerifyPinDialog({required this.title, required this.verify});
  final String title;
  final Future<bool> Function(String pin) verify;

  @override
  State<_VerifyPinDialog> createState() => _VerifyPinDialogState();
}

class _VerifyPinDialogState extends State<_VerifyPinDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_pin.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.verify(_pin.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN.';
        _pin.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _pinField(
        controller: _pin,
        label: 'PIN',
        errorText: _error,
        autofocus: true,
        onSubmitted: _busy ? null : _submit,
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm'),
        ),
      ],
    );
  }
}
