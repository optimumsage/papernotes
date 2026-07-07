import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/platform.dart';
import '../../data/attachments/attachment_store.dart';
import '../../data/models/attachment.dart';

/// Attachment sources. Files everywhere; the camera-based sources are
/// Android-only (desktop machines rarely have a usable document camera).
enum AttachmentSource { file, scanDocument, camera }

/// Entry point for the editor's attach action: on Android offers file /
/// document scan / camera via a bottom sheet, on desktop goes straight to the
/// file picker. Returns the imported attachments (empty when cancelled).
Future<List<NoteAttachment>> pickAttachments(
  BuildContext context,
  AttachmentStore store,
  String noteId,
) async {
  var source = AttachmentSource.file;
  if (isAndroidPlatform) {
    final chosen = await _chooseSource(context);
    if (chosen == null) return const [];
    source = chosen;
  }
  switch (source) {
    case AttachmentSource.file:
      return _pickFiles(store, noteId);
    case AttachmentSource.scanDocument:
      return _scanDocument(store, noteId);
    case AttachmentSource.camera:
      return _capturePhoto(store, noteId);
  }
}

Future<AttachmentSource?> _chooseSource(BuildContext context) {
  return showModalBottomSheet<AttachmentSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('Attach file'),
            onTap: () => Navigator.pop(context, AttachmentSource.file),
          ),
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('Scan document'),
            subtitle: const Text('Auto-detects and captures pages as PDF'),
            onTap: () => Navigator.pop(context, AttachmentSource.scanDocument),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(context, AttachmentSource.camera),
          ),
        ],
      ),
    ),
  );
}

Future<List<NoteAttachment>> _pickFiles(
    AttachmentStore store, String noteId) async {
  final files = await openFiles();
  // Imports are independent file copies — run them concurrently.
  return Future.wait([
    for (final file in files)
      store.import(noteId, file.path, displayName: file.name),
  ]);
}

/// ML Kit document scanner (Android): edge detection + auto-capture, returns a
/// (possibly multi-page) PDF.
Future<List<NoteAttachment>> _scanDocument(
    AttachmentStore store, String noteId) async {
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      documentFormats: {DocumentFormat.pdf},
      mode: ScannerMode.filter,
      pageLimit: 20,
      isGalleryImport: true,
    ),
  );
  try {
    final result = await scanner.scanDocument();
    final uri = result.pdf?.uri;
    if (uri == null) return const [];
    return [
      await store.import(noteId, uri, displayName: 'Scan ${_stamp()}.pdf'),
    ];
  } on PlatformException catch (e) {
    // Backing out of the scanner surfaces as an "Operation cancelled" error —
    // routine, not a failure.
    if ((e.message ?? '').toLowerCase().contains('cancel')) return const [];
    rethrow;
  } finally {
    await scanner.close();
  }
}

Future<List<NoteAttachment>> _capturePhoto(
    AttachmentStore store, String noteId) async {
  final photo = await ImagePicker().pickImage(source: ImageSource.camera);
  if (photo == null) return const [];
  return [
    await store.import(noteId, photo.path, displayName: 'Photo ${_stamp()}.jpg'),
  ];
}

String _stamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}.${two(now.minute)}.${two(now.second)}';
}
