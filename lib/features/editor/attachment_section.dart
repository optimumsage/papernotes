import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/app_snackbar.dart';
import '../../data/attachments/attachment_store.dart';
import '../../data/models/attachment.dart';

/// The editor's attachment list: one slim tile per file (image attachments get
/// a thumbnail), tap to open with the system handler, × to remove.
class AttachmentSection extends StatelessWidget {
  const AttachmentSection({
    super.key,
    required this.noteId,
    required this.attachments,
    required this.store,
    required this.onBg,
    required this.onRemove,
  });

  final String noteId;
  final List<NoteAttachment> attachments;
  final AttachmentStore store;

  /// Foreground color for the note's paper color (same contrast rule as the
  /// rest of the editor).
  final Color onBg;

  final void Function(NoteAttachment attachment) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.attach_file, size: 15, color: onBg.withValues(alpha: 0.55)),
            const SizedBox(width: 4),
            Text(
              'Attachments',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: onBg.withValues(alpha: 0.55)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final attachment in attachments)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _AttachmentTile(
              attachment: attachment,
              file: store.fileFor(noteId, attachment),
              onBg: onBg,
              onRemove: () => onRemove(attachment),
            ),
          ),
      ],
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.attachment,
    required this.file,
    required this.onBg,
    required this.onRemove,
  });

  final NoteAttachment attachment;
  final File file;
  final Color onBg;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: onBg.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              _leading(context),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: onBg),
                    ),
                    Text(
                      formatBytes(attachment.size),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: onBg.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove attachment',
                icon: Icon(Icons.close,
                    size: 18, color: onBg.withValues(alpha: 0.6)),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(BuildContext context) {
    if (attachment.kind == AttachmentKind.image) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          file,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          // Decode at the thumbnail's physical size — never the full camera
          // resolution.
          cacheWidth:
              (40 * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, _, _) => _iconBox(Icons.image_outlined),
        ),
      );
    }
    return _iconBox(attachment.kind == AttachmentKind.pdf
        ? Icons.picture_as_pdf_outlined
        : Icons.insert_drive_file_outlined);
  }

  Widget _iconBox(IconData icon) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Icon(icon, color: onBg.withValues(alpha: 0.7)),
    );
  }

  Future<void> _open(BuildContext context) async {
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && context.mounted) {
      showAppSnackBar(context, 'Could not open ${attachment.name}');
    }
  }
}

/// Human-readable size, e.g. `348 KB`, `2.1 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
