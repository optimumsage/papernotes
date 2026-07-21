import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/data/models/note.dart';
import 'package:papernote/features/notes_list/note_card.dart';

Note _note(String id, String body) => Note(
      id: id,
      type: NoteType.note,
      title: 'Title $id',
      body: body,
      createdAt: 1000,
      updatedAt: 1000,
    );

Widget _harness(Note note,
        {String? folderName, bool uniform = true, double width = 300}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: NoteCard(
              note: note,
              onTap: () {},
              uniform: uniform,
              folderName: folderName,
            ),
          ),
        ),
      ),
    );

void main() {
  // A one-line note and a very long note must render the list row at exactly
  // the same size (uniform width + height), with the long body clipped rather
  // than overflowing.
  const shortBody = '[{"insert":"hi\\n"}]';
  final longBody =
      '[{"insert":"${List.filled(40, 'a long wrapping line of text').join(' ')}\\n"}]';

  testWidgets('uniform list cards have identical size regardless of content',
      (tester) async {
    await tester.pumpWidget(_harness(_note('a', shortBody)));
    await tester.pumpAndSettle();
    final shortSize = tester.getSize(find.byType(NoteCard));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_harness(_note('b', longBody)));
    await tester.pumpAndSettle();
    final longSize = tester.getSize(find.byType(NoteCard));
    expect(tester.takeException(), isNull, reason: 'long body must not overflow');

    expect(longSize.height, shortSize.height);
    expect(longSize.width, shortSize.width);
    expect(shortSize.width, 300);
  });

  testWidgets('the folder tag shows only when a folder name is given',
      (tester) async {
    await tester.pumpWidget(_harness(_note('a', shortBody)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
    expect(find.textContaining('Edited'), findsOneWidget);

    await tester.pumpWidget(
        _harness(_note('a', shortBody), folderName: 'Shopping'));
    await tester.pumpAndSettle();
    expect(find.text('Shopping'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.textContaining('Edited'), findsOneWidget,
        reason: 'the tag sits alongside the timestamp, not instead of it');
  });

  testWidgets('the folder tag never changes the uniform row height',
      (tester) async {
    await tester.pumpWidget(_harness(_note('a', longBody)));
    await tester.pumpAndSettle();
    final plain = tester.getSize(find.byType(NoteCard));

    await tester
        .pumpWidget(_harness(_note('a', longBody), folderName: 'Shopping'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(NoteCard)).height, plain.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long folder name ellipsizes instead of overflowing',
      (tester) async {
    // Narrow column + huge text scale + a long name: the worst case for the
    // footer row, which must degrade to an ellipsis rather than throw.
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 130,
              child: NoteCard(
                note: _note('a', shortBody),
                onTap: () {},
                folderName: 'An Extremely Long Folder Name That Will Not Fit',
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the footer must not overflow');
  });
}
