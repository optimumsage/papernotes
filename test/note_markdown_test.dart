import 'package:flutter_test/flutter_test.dart';
import 'package:papernote/core/note_markdown.dart';

void main() {
  group('tokenizeMarkdown', () {
    test('plain text yields a single plain token', () {
      final tokens = tokenizeMarkdown('hello world');
      expect(tokens.length, 1);
      expect(tokens.single.text, 'hello world');
      expect(tokens.single.marker, isFalse);
      expect(tokens.single.bold, isFalse);
    });

    test('bold is parsed with markers preserved', () {
      final tokens = tokenizeMarkdown('a **b** c');
      // 'a ' | '**' | 'b' | '**' | ' c'
      expect(tokens.map((t) => t.text).join(), 'a **b** c');
      final bold = tokens.firstWhere((t) => t.bold);
      expect(bold.text, 'b');
      expect(tokens.where((t) => t.marker).length, 2);
    });

    test('italic and underline are distinguished', () {
      final italic = tokenizeMarkdown('*x*').firstWhere((t) => !t.marker);
      expect(italic.italic, isTrue);
      final underline = tokenizeMarkdown('_y_').firstWhere((t) => !t.marker);
      expect(underline.underline, isTrue);
    });

    test('every character is preserved (round-trip)', () {
      const src = 'mix **bold** and *italic* and _under_ done';
      expect(tokenizeMarkdown(src).map((t) => t.text).join(), src);
    });
  });

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
}
