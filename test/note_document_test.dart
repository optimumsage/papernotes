import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/features/editor/note_document.dart';

void main() {
  group('documentFromBody / bodyFromDocument', () {
    test('null/empty body produces an empty document and empty body', () {
      final doc = documentFromBody(null);
      expect(doc.toPlainText().trim(), '');
      expect(bodyFromDocument(doc), '');
      expect(bodyFromDocument(documentFromBody('   ')), '');
    });

    test('legacy plain text migrates and survives a round-trip', () {
      final doc = documentFromBody('hello world');
      expect(doc.toPlainText(), 'hello world\n');
      final body = bodyFromDocument(doc);
      expect(body, isNotNull);
      // Re-opening the serialized Delta yields the same text.
      expect(documentFromBody(body).toPlainText(), 'hello world\n');
    });

    test('legacy markdown markers are stripped during migration', () {
      expect(documentFromBody('a **b** c').toPlainText(), 'a b c\n');
      expect(documentFromBody('- one\n- two').toPlainText(), '• one\n• two\n');
    });

    test('a Delta JSON document is parsed as rich text', () {
      const delta = '[{"insert":"hi "},'
          '{"insert":"bold","attributes":{"b":true}},'
          '{"insert":"\\n"}]';
      final doc = documentFromBody(delta);
      expect(doc.toPlainText(), 'hi bold\n');
      // Bold attribute is preserved through a re-serialize.
      expect(bodyFromDocument(doc), contains('"b":true'));
    });

    test('malformed JSON falls back to plain text (never throws)', () {
      expect(documentFromBody('[oops not json').toPlainText(),
          '[oops not json\n');
    });
  });
}
