import 'package:uuid/uuid.dart';

import '../../core/note_body.dart';
import '../local/database.dart';
import '../models/checklist_item.dart';
import '../models/note.dart';

/// The single entry point the UI uses to read and mutate notes. Every write
/// stamps `updatedAt` and marks the row `dirty` so the sync engine knows to
/// push it. The repository never talks to Drive directly.
class NoteRepository {
  NoteRepository(this._db, {this.onChanged});

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Called after every persisted mutation so callers can react (e.g. trigger a
  /// debounced Drive sync). Optional so tests can construct the repo bare.
  final void Function()? onChanged;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Stream<List<Note>> watchActive() => _db.watchActive();
  Stream<List<Note>> watchArchived() => _db.watchArchived();
  Stream<List<Note>> watchTrashed() => _db.watchTrashed();

  Future<Note?> getNote(String id) => _db.getNote(id);

  /// Create a fresh note/checklist in memory. Not persisted until [save] is
  /// called — lets the editor discard empty notes without ever writing a row.
  /// An [id] may be supplied so the route and the row share the same UUID;
  /// [color] seeds the user's default note color. [folderId] files the new
  /// note into a folder (e.g. the one currently being viewed).
  Note newDraft(NoteType type, {String? id, int color = 0, String? folderId}) {
    final now = _now;
    return Note(
      id: id ?? _uuid.v4(),
      type: type,
      color: color,
      folderId: folderId,
      items: type == NoteType.checklist
          ? [ChecklistItem(id: _uuid.v4())]
          : const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  ChecklistItem newItem() => ChecklistItem(id: _uuid.v4());

  /// Persist a note, bumping `updatedAt` and marking it dirty for sync.
  Future<void> save(Note note) async {
    await _db.upsertNote(note.copyWith(updatedAt: _now), dirty: true);
    onChanged?.call();
  }

  // ---- Lifecycle: archive / trash / restore / permanent delete ----

  Future<void> _setStatus(String id, NoteStatus status, {int? trashedAt}) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    await _db.upsertNote(
      note.copyWith(
        status: status,
        trashedAt: trashedAt,
        clearTrashedAt: status != NoteStatus.trashed,
        updatedAt: _now,
      ),
      dirty: true,
    );
    onChanged?.call();
  }

  /// Move a note to Trash (recoverable). Records when it was trashed so it can
  /// be auto-emptied later.
  Future<void> moveToTrash(String id) =>
      _setStatus(id, NoteStatus.trashed, trashedAt: _now);

  /// Restore a trashed or archived note back to the active list.
  Future<void> restore(String id) => _setStatus(id, NoteStatus.active);

  Future<void> archive(String id) => _setStatus(id, NoteStatus.archived);

  Future<void> unarchive(String id) => _setStatus(id, NoteStatus.active);

  /// Permanently delete: flips the tombstone so the removal propagates to other
  /// devices on the next sync; the row + remote file are purged by the sync
  /// engine after the retention window (or immediately when sync is off).
  Future<void> deletePermanently(String id) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    final now = _now;
    await _db.upsertNote(
      note.copyWith(deleted: true, deletedAt: now, updatedAt: now),
      dirty: true,
    );
    onChanged?.call();
  }

  /// Permanently delete every note currently in Trash.
  Future<void> emptyTrash() async {
    for (final note in await _db.trashedNotes()) {
      await deletePermanently(note.id);
    }
  }

  /// Auto-empty: permanently delete trashed notes older than [retentionDays].
  /// Runs on launch (offline-capable); `retentionDays <= 0` disables it.
  Future<void> autoEmptyTrash(int retentionDays) async {
    if (retentionDays <= 0) return;
    final cutoff = _now - retentionDays * Duration.millisecondsPerDay;
    for (final note in await _db.trashedNotes()) {
      final since = note.trashedAt ?? note.updatedAt;
      if (since < cutoff) await deletePermanently(note.id);
    }
  }

  /// Permanently remove a draft that was never meaningfully filled in.
  Future<void> discardDraft(String id) => _db.hardDelete(id);

  Future<void> setColor(String id, int color) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    await _db.upsertNote(
      note.copyWith(color: color, updatedAt: _now),
      dirty: true,
    );
    onChanged?.call();
  }

  /// Move a note into [folderId] (null unfiles it).
  Future<void> setFolder(String id, String? folderId) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    await _db.upsertNote(
      note.copyWith(
        folderId: folderId,
        clearFolderId: folderId == null,
        updatedAt: _now,
      ),
      dirty: true,
    );
    onChanged?.call();
  }

  Future<void> setPinned(String id, bool pinned) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    await _db.upsertNote(
      note.copyWith(pinned: pinned, updatedAt: _now),
      dirty: true,
    );
    onChanged?.call();
  }

  /// Set or clear a note's reminder. [type] null (or [ReminderType.none])
  /// clears it; [at] is the trigger time (epoch ms) for a timed alarm.
  Future<void> setReminder(String id, ReminderType? type, int? at) async {
    final note = await _db.getNote(id);
    if (note == null) return;
    final effective = type ?? ReminderType.none;
    await _db.upsertNote(
      note.copyWith(
        reminderType: effective,
        reminderAt: effective == ReminderType.alarm ? at : null,
        clearReminderAt: effective != ReminderType.alarm,
        updatedAt: _now,
      ),
      dirty: true,
    );
    onChanged?.call();
  }
}

/// Case-insensitive search over title, body and checklist item text. Kept in
/// the repository layer's file so both the list screen and tests can reuse it.
List<Note> searchNotes(List<Note> notes, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return notes;
  return notes.where((n) {
    if ((n.title ?? '').toLowerCase().contains(q)) return true;
    if (plainTextFromBody(n.body).toLowerCase().contains(q)) return true;
    return n.items.any((i) => i.text.toLowerCase().contains(q));
  }).toList();
}
