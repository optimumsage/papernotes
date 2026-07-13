import 'dart:io';

import 'package:drift/native.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/attachments/attachment_store.dart';
import 'package:papernote/data/local/database.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/data/settings_service.dart';
import 'package:papernote/features/editor/editor_screen.dart';
import 'package:papernote/features/editor/ruled_lines_painter.dart';
import 'package:papernote/providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mounts the editor inside the same provider + localization setup the real app
/// uses, so this catches a missing Fleather localizations delegate or a build
/// failure in the rich-text body.
Widget _harness(AppDatabase db, Widget child) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      attachmentStoreProvider.overrideWithValue(
          AttachmentStore(Directory.systemTemp.createTempSync('att'))),
    ],
    child: MaterialApp(
      localizationsDelegates: const [FleatherLocalizations.delegate],
      home: child,
    ),
  );
}

void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('new note editor mounts with the Fleather body and hint',
      (tester) async {
    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n1', isNew: true, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FleatherEditor), findsOneWidget);
    expect(find.text('Note'), findsOneWidget); // placeholder while empty
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens an existing rich-text (Delta) note without error',
      (tester) async {
    const delta = '[{"insert":"saved body\\n"}]';
    await db.upsertNote(
      Note(
        id: 'n2',
        type: NoteType.note,
        body: delta,
        createdAt: 1,
        updatedAt: 1,
      ),
      dirty: false,
    );

    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n2', isNew: false, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FleatherEditor), findsOneWidget);
    expect(find.text('Note'), findsNothing); // not empty → no placeholder
    expect(tester.takeException(), isNull);
  });

  testWidgets('ruled-paper line spacing matches the editor line height',
      (tester) async {
    // A multi-paragraph body: any drift between the painter's spacing and the
    // text's real line height accumulates and is what caused rules to overlap
    // text further down the note.
    const delta = '[{"insert":"line one\\nline two\\nline three\\n'
        'line four\\nline five\\nline six\\n"}]';
    await db.upsertNote(
      Note(id: 'n3', type: NoteType.note, body: delta, createdAt: 1, updatedAt: 1),
      dirty: false,
    );

    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n3', isNew: false, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    // The painter's configured line spacing.
    final ruled = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<RuledLinesPainter>()
        .single;

    // The editor's actual per-line height: vertical gap between consecutive
    // rendered text lines (one RichText per Fleather line).
    final tops = <double>[];
    for (final e in find
        .descendant(
            of: find.byType(FleatherEditor), matching: find.byType(RichText))
        .evaluate()) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        tops.add(ro.localToGlobal(Offset.zero).dy);
      }
    }
    tops.sort();
    expect(tops.length, greaterThanOrEqualTo(3));
    for (var i = 1; i < tops.length; i++) {
      // Each line advances by exactly the painter's spacing (no drift).
      expect(tops[i] - tops[i - 1], closeTo(ruled.lineHeight, 0.01));
    }
  });

  testWidgets('ruled lines fill the page height on a near-empty note',
      (tester) async {
    // Empty note: the ruled background must still cover (roughly) the whole
    // viewport, not just the single caret line — that was the "lines only on
    // text" bug.
    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n4', isNew: true, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    final ruledFinder = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is RuledLinesPainter);
    final box = tester.renderObject<RenderBox>(ruledFinder);
    // One line of text is ~22px; the fill must be a large fraction of the
    // 600px test viewport (minus app bar / padding), proving it isn't
    // content-sized any more.
    expect(box.size.height, greaterThan(300));
  });

  testWidgets('the note body editor owns its scroll (scrollable) for selection',
      (tester) async {
    // Selection drag-to-extend on Android only works when the FleatherEditor
    // manages its own scroll; assert we build it in that mode with a controller.
    const delta = '[{"insert":"select me please\\n"}]';
    await db.upsertNote(
      Note(id: 'n5', type: NoteType.note, body: delta, createdAt: 1, updatedAt: 1),
      dirty: false,
    );
    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n5', isNew: false, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    final editor = tester.widget<FleatherEditor>(find.byType(FleatherEditor));
    expect(editor.scrollable, isTrue);
    expect(editor.scrollController, isNotNull);

    // A range selection can be installed and read back (selection is enabled).
    editor.controller
        .updateSelection(const TextSelection(baseOffset: 0, extentOffset: 6));
    await tester.pump();
    expect(editor.controller.selection.isCollapsed, isFalse);
  });

  testWidgets('note metadata footer stays outside the scrollable editor',
      (tester) async {
    // Regression: the created/edited line used to be pushed to the bottom of the
    // ruled body and clipped in view mode. It must now sit in the pinned footer,
    // below the editor — not a descendant of the FleatherEditor.
    const delta = '[{"insert":"hi\\n"}]';
    await db.upsertNote(
      Note(id: 'n6', type: NoteType.note, body: delta, createdAt: 1, updatedAt: 1),
      dirty: false,
    );
    await tester.pumpWidget(_harness(
      db,
      const EditorScreen(noteId: 'n6', isNew: false, type: NoteType.note),
    ));
    await tester.pumpAndSettle();

    final meta = find.textContaining('Created ');
    expect(meta, findsOneWidget);
    expect(
      find.descendant(of: find.byType(FleatherEditor), matching: meta),
      findsNothing,
    );
    // And it renders within the visible viewport (not clipped off-screen).
    final size = tester.getSize(find.byType(MaterialApp));
    expect(tester.getBottomLeft(meta).dy, lessThanOrEqualTo(size.height));
  });
}
