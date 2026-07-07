import 'dart:convert';

import 'attachment.dart';
import 'checklist_item.dart';

enum NoteType { note, checklist }

/// A note's reminder mode. `none` = no reminder; `alarm` = fire a notification at
/// [Note.reminderAt]; `pinned` = keep a persistent ("pinned to status bar")
/// notification while the reminder is set.
enum ReminderType { none, alarm, pinned }

/// Lifecycle state of a note. `active` notes show on the main grid, `archived`
/// in the Archive view, `trashed` in Trash. Permanent deletion is tracked
/// separately by the `deleted` tombstone flag.
enum NoteStatus { active, archived, trashed }

/// Domain model for a note or checklist. This is the in-memory representation
/// used by the UI and the sync engine. It maps to the drift `notes` row and to
/// the `<id>.json` file stored in Google Drive's appDataFolder.
class Note {
  final String id;
  final NoteType type;
  final String? title;
  final String? body; // used by NoteType.note
  final List<ChecklistItem> items; // used by NoteType.checklist
  final int color; // index into NoteColors.swatches
  final bool pinned;
  final String? folderId; // owning folder id, or null when unfiled
  final NoteStatus status; // active | archived | trashed
  final int? trashedAt; // epoch ms — when it entered Trash (auto-empty timer)
  final int createdAt; // epoch ms
  final int updatedAt; // epoch ms — drives last-write-wins
  final bool deleted; // hard tombstone (permanent delete)
  final int? deletedAt; // epoch ms
  final ReminderType reminderType; // none | alarm | pinned
  final int? reminderAt; // epoch ms — trigger time for ReminderType.alarm

  /// Files attached to this note. Device-local: excluded from the Drive sync
  /// payload (see [NoteAttachment]).
  final List<NoteAttachment> attachments;

  const Note({
    required this.id,
    required this.type,
    this.title,
    this.body,
    this.items = const [],
    this.color = 0,
    this.pinned = false,
    this.folderId,
    this.status = NoteStatus.active,
    this.trashedAt,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.deletedAt,
    this.reminderType = ReminderType.none,
    this.reminderAt,
    this.attachments = const [],
  });

  bool get isChecklist => type == NoteType.checklist;
  bool get hasTitle => title != null && title!.trim().isNotEmpty;
  bool get isArchived => status == NoteStatus.archived;
  bool get isTrashed => status == NoteStatus.trashed;
  bool get hasReminder => reminderType != ReminderType.none;
  bool get hasAttachments => attachments.isNotEmpty;

  /// True when the note carries no user content and can be safely discarded.
  /// An attachment counts as content.
  bool get isEmpty {
    if (attachments.isNotEmpty) return false;
    final noTitle = title == null || title!.trim().isEmpty;
    if (isChecklist) {
      return noTitle && items.every((i) => i.text.trim().isEmpty);
    }
    return noTitle && (body == null || body!.trim().isEmpty);
  }

  Note copyWith({
    String? title,
    bool clearTitle = false,
    String? body,
    List<ChecklistItem>? items,
    int? color,
    bool? pinned,
    String? folderId,
    bool clearFolderId = false,
    NoteStatus? status,
    int? trashedAt,
    bool clearTrashedAt = false,
    int? updatedAt,
    bool? deleted,
    int? deletedAt,
    ReminderType? reminderType,
    int? reminderAt,
    bool clearReminderAt = false,
    List<NoteAttachment>? attachments,
  }) {
    return Note(
      id: id,
      type: type,
      title: clearTitle ? null : (title ?? this.title),
      body: body ?? this.body,
      items: items ?? this.items,
      color: color ?? this.color,
      pinned: pinned ?? this.pinned,
      folderId: clearFolderId ? null : (folderId ?? this.folderId),
      status: status ?? this.status,
      trashedAt: clearTrashedAt ? null : (trashedAt ?? this.trashedAt),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
      reminderType: reminderType ?? this.reminderType,
      reminderAt: clearReminderAt ? null : (reminderAt ?? this.reminderAt),
      attachments: attachments ?? this.attachments,
    );
  }

  // ---- JSON (Drive file payload) ----

  /// Serialized form written to `<id>.json` in Drive. Carries every field the
  /// sync engine needs, including the tombstone flags. [attachments] carry
  /// their `driveFileId` so other devices can fetch the binaries.
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'body': body,
        'items': items.map((i) => i.toJson()).toList(),
        'color': color,
        'pinned': pinned,
        'folderId': folderId,
        'status': status.name,
        'trashedAt': trashedAt,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'deleted': deleted,
        'deletedAt': deletedAt,
        'reminderType': reminderType.name,
        'reminderAt': reminderAt,
        'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory Note.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List?) ?? const [];
    return Note(
      id: json['id'] as String,
      type: NoteType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => NoteType.note,
      ),
      title: json['title'] as String?,
      body: json['body'] as String?,
      items: rawItems
          .map((e) => ChecklistItem.fromJson(
              (e as Map).cast<String, dynamic>()))
          .toList(),
      color: (json['color'] as num?)?.toInt() ?? 0,
      pinned: (json['pinned'] as bool?) ?? false,
      folderId: json['folderId'] as String?,
      status: NoteStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => NoteStatus.active,
      ),
      trashedAt: (json['trashedAt'] as num?)?.toInt(),
      createdAt: (json['createdAt'] as num).toInt(),
      updatedAt: (json['updatedAt'] as num).toInt(),
      deleted: (json['deleted'] as bool?) ?? false,
      deletedAt: (json['deletedAt'] as num?)?.toInt(),
      reminderType: ReminderType.values.firstWhere(
        (r) => r.name == json['reminderType'],
        orElse: () => ReminderType.none,
      ),
      reminderAt: (json['reminderAt'] as num?)?.toInt(),
      attachments: ((json['attachments'] as List?) ?? const [])
          .map((e) => NoteAttachment.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  factory Note.decode(String source) =>
      Note.fromJson((jsonDecode(source) as Map).cast<String, dynamic>());

  /// Encode the items list for storage in the drift `items` text column.
  String itemsToColumn() => jsonEncode(items.map((i) => i.toJson()).toList());

  static List<ChecklistItem> itemsFromColumn(String? source) {
    if (source == null || source.isEmpty) return const [];
    final decoded = jsonDecode(source) as List;
    return decoded
        .map((e) => ChecklistItem.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Encode the attachments list for the drift `attachments` text column
  /// (null when there are none, keeping untouched rows compact).
  String? attachmentsToColumn() =>
      attachments.isEmpty ? null : NoteAttachment.encodeList(attachments);
}
