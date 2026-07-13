import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows the generated master key exactly once. The user must copy/save it and
/// tick the confirmation before it can be committed — there is no recovery if
/// it's lost. Returns true when the user confirmed they've saved it.
Future<bool> showMasterKeyDialog(
  BuildContext context, {
  required String masterKey,
  required bool isChange,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _MasterKeyDialog(masterKey: masterKey, isChange: isChange),
  );
  return result ?? false;
}

class _MasterKeyDialog extends StatefulWidget {
  const _MasterKeyDialog({required this.masterKey, required this.isChange});

  final String masterKey;
  final bool isChange;

  @override
  State<_MasterKeyDialog> createState() => _MasterKeyDialogState();
}

class _MasterKeyDialogState extends State<_MasterKeyDialog> {
  bool _saved = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.isChange ? 'Your new master key' : 'Your master key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Save this key somewhere safe (a password manager). It is shown '
              'only once and encrypts all your notes. Without it your notes '
              'cannot be recovered, and other devices will ask for it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.masterKey,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                label: Text(_copied ? 'Copied' : 'Copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: widget.masterKey));
                  if (context.mounted) setState(() => _copied = true);
                },
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _saved,
              onChanged: (v) => setState(() => _saved = v ?? false),
              title: const Text('I have saved my master key'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saved ? () => Navigator.pop(context, true) : null,
          child: Text(widget.isChange ? 'Change key' : 'Enable'),
        ),
      ],
    );
  }
}
