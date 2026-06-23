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

Widget _harness(Note note) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: NoteCard(note: note, onTap: () {}, uniform: true),
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
}
