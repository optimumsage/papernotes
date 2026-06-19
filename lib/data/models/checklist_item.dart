/// A single row in a checklist note. Stored as JSON inside the note's `items`
/// column (plain-text model — no separate table).
class ChecklistItem {
  final String id;
  String text;
  bool checked;

  ChecklistItem({
    required this.id,
    this.text = '',
    this.checked = false,
  });

  ChecklistItem copyWith({String? text, bool? checked}) => ChecklistItem(
        id: id,
        text: text ?? this.text,
        checked: checked ?? this.checked,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'checked': checked,
      };

  factory ChecklistItem.fromJson(Map<String, dynamic> json) => ChecklistItem(
        id: json['id'] as String,
        text: (json['text'] as String?) ?? '',
        checked: (json['checked'] as bool?) ?? false,
      );
}
