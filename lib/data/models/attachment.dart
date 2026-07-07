import 'dart:convert';

import 'package:path/path.dart' as p;

/// Broad attachment category, derived from the stored file's extension. Drives
/// the icon/preview treatment in the UI (images get a thumbnail).
enum AttachmentKind { image, pdf, other }

/// Metadata for one file attached to a note. The binary lives on disk in the
/// app's attachment store (`attachments/<noteId>/<fileName>`); the note row
/// only carries this metadata as JSON.
///
/// Attachments are **local to the device**: they are deliberately excluded
/// from the Drive sync payload (binaries would bloat appDataFolder and the
/// metadata would dangle on other devices), and the sync engine preserves the
/// local attachments column when applying remote note updates.
class NoteAttachment {
  final String id;

  /// Display name (the original file name, e.g. `invoice.pdf`).
  final String name;

  /// Stored file name inside the note's attachment directory
  /// (`<id><extension>` — unique, collision-free).
  final String fileName;

  /// Size in bytes at import time.
  final int size;

  final int createdAt; // epoch ms

  const NoteAttachment({
    required this.id,
    required this.name,
    required this.fileName,
    required this.size,
    required this.createdAt,
  });

  static const _imageExts = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'
  };

  AttachmentKind get kind {
    final ext = p.extension(fileName).toLowerCase();
    if (_imageExts.contains(ext)) return AttachmentKind.image;
    if (ext == '.pdf') return AttachmentKind.pdf;
    return AttachmentKind.other;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileName': fileName,
        'size': size,
        'createdAt': createdAt,
      };

  factory NoteAttachment.fromJson(Map<String, dynamic> json) => NoteAttachment(
        id: json['id'] as String,
        name: json['name'] as String,
        fileName: json['fileName'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );

  /// Encode a list for storage in the drift `attachments` text column.
  static String encodeList(List<NoteAttachment> attachments) =>
      jsonEncode(attachments.map((a) => a.toJson()).toList());

  static List<NoteAttachment> decodeList(String? source) {
    if (source == null || source.isEmpty) return const [];
    final decoded = jsonDecode(source) as List;
    return decoded
        .map((e) =>
            NoteAttachment.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }
}
