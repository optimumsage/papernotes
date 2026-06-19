import 'dart:convert';

/// Domain model for a folder used to group notes. Folders are flat (no
/// nesting). Like [Note], a folder maps to a drift `folders` row and to a
/// `folder-<id>.json` file in Google Drive's appDataFolder. Deletions travel
/// as tombstones (`deleted` / `deletedAt`) and are purged after the retention
/// window, mirroring the note lifecycle.
class Folder {
  final String id;
  final String name;
  final int createdAt; // epoch ms
  final int updatedAt; // epoch ms — drives last-write-wins
  final bool deleted; // tombstone (permanent delete)
  final int? deletedAt; // epoch ms

  const Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.deletedAt,
  });

  Folder copyWith({
    String? name,
    int? updatedAt,
    bool? deleted,
    int? deletedAt,
  }) {
    return Folder(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  // ---- JSON (Drive file payload: folder-<id>.json) ----

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'deleted': deleted,
        'deletedAt': deletedAt,
      };

  String encode() => jsonEncode(toJson());

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        createdAt: (json['createdAt'] as num).toInt(),
        updatedAt: (json['updatedAt'] as num).toInt(),
        deleted: (json['deleted'] as bool?) ?? false,
        deletedAt: (json['deletedAt'] as num?)?.toInt(),
      );

  factory Folder.decode(String source) =>
      Folder.fromJson((jsonDecode(source) as Map).cast<String, dynamic>());
}
