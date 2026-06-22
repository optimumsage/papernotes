import 'package:drift/native.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
