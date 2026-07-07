import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/attachment.dart';

/// Owns the on-disk attachment binaries, stored under the app-support
/// directory as `attachments/&lt;noteId&gt;/&lt;attachmentId&gt;&lt;ext&gt;`.
/// Metadata lives on the note row ([NoteAttachment]); this class only moves
/// bytes.
///
/// App-support (not documents) keeps the files out of the user's visible
/// Documents folder on desktop while remaining app-private on Android.
class AttachmentStore {
  AttachmentStore(this._root);

  final Directory _root;
  static const _uuid = Uuid();

  /// Resolve the platform storage location. Called once during bootstrap.
  static Future<AttachmentStore> open() async {
    final dir = await getApplicationSupportDirectory();
    return AttachmentStore(Directory(p.join(dir.path, 'attachments')));
  }

  Directory dirFor(String noteId) => Directory(p.join(_root.path, noteId));

  File fileFor(String noteId, NoteAttachment attachment) =>
      File(p.join(_root.path, noteId, attachment.fileName));

  /// Copy [sourcePath] (a plain path or a `file://` URI) into the note's
  /// attachment directory and return the metadata to put on the note.
  /// [displayName] defaults to the source file's name.
  Future<NoteAttachment> import(
    String noteId,
    String sourcePath, {
    String? displayName,
  }) async {
    final path = sourcePath.startsWith('file://')
        ? Uri.parse(sourcePath).toFilePath()
        : sourcePath;
    final source = File(path);
    final id = _uuid.v4();
    final name = (displayName?.trim().isNotEmpty ?? false)
        ? displayName!.trim()
        : p.basename(path);
    final fileName = '$id${p.extension(name).toLowerCase()}';

    final dir = dirFor(noteId);
    await dir.create(recursive: true);
    final copied = await source.copy(p.join(dir.path, fileName));
    final size = await copied.length();

    return NoteAttachment(
      id: id,
      name: name,
      fileName: fileName,
      size: size,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Delete one attachment's binary. Missing files are fine (already gone).
  Future<void> remove(String noteId, NoteAttachment attachment) async {
    try {
      await fileFor(noteId, attachment).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }

  /// Delete every binary belonging to [noteId] (note permanently deleted or
  /// draft discarded).
  Future<void> removeAllFor(String noteId) async {
    final dir = dirFor(noteId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Remove directories for notes that no longer exist (e.g. a permanent
  /// delete synced in from another device bypasses [removeAllFor] here).
  /// Run fire-and-forget on launch.
  ///
  /// [isLive] is queried fresh per directory right before deleting, and
  /// recently-modified directories are skipped entirely — an attach-in-progress
  /// creates the directory before its (new) note row is first saved, so a
  /// stale snapshot of note ids must never be trusted here.
  Future<void> sweepOrphans(
    Future<bool> Function(String noteId) isLive, {
    Duration recentGuard = const Duration(minutes: 10),
  }) async {
    if (!await _root.exists()) return;
    final cutoff = DateTime.now().subtract(recentGuard);
    await for (final entry in _root.list()) {
      if (entry is! Directory) continue;
      try {
        final stat = await entry.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        if (await isLive(p.basename(entry.path))) continue;
        await entry.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup; retried next launch.
      }
    }
  }
}
