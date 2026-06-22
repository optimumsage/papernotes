import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/note_body.dart';
import 'package:papernote/core/note_markdown.dart';

void main() {
  group('stripMarkdown', () {
    test('removes inline emphasis markers', () {
      expect(stripMarkdown('a **b** c'), 'a b c');
      expect(stripMarkdown('*i* and _u_'), 'i and u');
    });

    test('normalizes dash bullets to •', () {
      expect(stripMarkdown('- item one\n- item two'), '• item one\n• item two');
    });

    test('leaves plain text untouched', () {
      expect(stripMarkdown('nothing to strip'), 'nothing to strip');
    });

    test('handles combined bullets and emphasis', () {
      expect(stripMarkdown('- buy **milk**'), '• buy milk');
    });
  });

  group('plainTextFromBody', () {
    test('null/empty returns empty', () {
      expect(plainTextFromBody(null), '');
      expect(plainTextFromBody(''), '');
    });

    test('extracts text from a Delta JSON document', () {
      const delta = '[{"insert":"hello "},'
          '{"insert":"world","attributes":{"b":true}},'
          '{"insert":"\\n"}]';
      expect(plainTextFromBody(delta), 'hello world\n');
    });

    test('falls back to markdown-stripping for legacy plain text', () {
      expect(plainTextFromBody('a **b**'), 'a b');
    });

    test('malformed JSON is treated as legacy text', () {
      expect(plainTextFromBody('[not valid json'), '[not valid json');
    });
  });
}
