import 'package:code_forge/LSP/lsp.dart';
import 'package:code_forge/code_forge/syntax_highlighter.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_highlight/languages/typescript.dart';

const _a = TextStyle(color: Color(0xFF111111));
const _b = TextStyle(color: Color(0xFF222222));

SemanticWordSpan _span(int start, int end, TextStyle style) =>
    SemanticWordSpan(startChar: start, endChar: end, word: '', style: style);

/// Spans as `line: [start, end)` strings, for readable expectations.
Map<int, List<String>> _layout(Map<int, List<SemanticWordSpan>> spans) => {
  for (final MapEntry(:key, :value) in spans.entries)
    key: [for (final s in value) '${s.startChar}-${s.endChar}'],
};

Map<int, List<String>> _shift(
  Map<int, List<SemanticWordSpan>> spans, {
  required int line,
  required int column,
  String deleted = '',
  String inserted = '',
}) => _layout(
  shiftSemanticSpans(
    spans,
    LineEdit.fromText(
      line: line,
      column: column,
      deletedText: deleted,
      insertedText: inserted,
    ),
  ),
);

void main() {
  // Line 1 is `foo(bar);` with spans on `foo` and `bar`; line 2 has one span.
  Map<int, List<SemanticWordSpan>> spans() => {
    1: [_span(0, 3, _a), _span(4, 7, _b)],
    2: [_span(2, 5, _a)],
  };

  test(
    'typing a word character grows the span and moves the rest of the line',
    () {
      expect(_shift(spans(), line: 1, column: 3, inserted: 'd'), {
        1: ['0-4', '5-8'],
        2: ['2-5'],
      });
    },
  );

  test('typing punctuation after a word keeps the word as it was', () {
    expect(_shift(spans(), line: 1, column: 3, inserted: '.'), {
      1: ['0-3', '5-8'],
      2: ['2-5'],
    });
  });

  test('Enter moves the rest of the line down, after the new indentation', () {
    expect(_shift(spans(), line: 1, column: 4, inserted: '\n  '), {
      1: ['0-3'],
      2: ['2-5'],
      3: ['2-5'],
    });
  });

  test('joining lines moves the next line up to the end of this one', () {
    final joined = {
      1: [_span(0, 3, _a)],
      2: [_span(2, 5, _b)],
      4: [_span(0, 1, _a)],
    };
    // Delete "\n  " at the end of line 1 (column 9).
    expect(_shift(joined, line: 1, column: 9, deleted: '\n  '), {
      1: ['0-3', '9-12'],
      3: ['0-1'],
    });
  });

  test(
    'deleting over a span drops it but keeps parts outside the deletion',
    () {
      expect(_shift(spans(), line: 1, column: 2, deleted: '(ba'), {
        1: ['0-2', '2-4'],
        2: ['2-5'],
      });
    },
  );

  test('document offsets are turned into columns of the edited line', () {
    const text = 'const x = 1;\nfoo(bar);\n';
    SyntaxHighlighter.semanticStyleResolver = (type, modifiers, language) => _a;
    addTearDown(() => SyntaxHighlighter.semanticStyleResolver = null);
    final highlighter = SyntaxHighlighter(
      language: langTypescript,
      editorTheme: const {'root': TextStyle(color: Color(0xFFFFFFFF))},
      languageId: 'typescript',
    );
    highlighter.updateSemanticTokens(
      const [
        LspSemanticToken(
          line: 1,
          start: 0,
          length: 3,
          typeIndex: 0,
          modifierBitmask: 0,
          tokenTypeName: 'function',
        ),
        LspSemanticToken(
          line: 1,
          start: 4,
          length: 3,
          typeIndex: 0,
          modifierBitmask: 0,
          tokenTypeName: 'variable',
        ),
      ],
      (line) => text.split('\n')[line],
      3,
    );
    final before = _layout(highlighter.semanticSpans);
    expect(before[1], hasLength(2));

    // Type "d" after `foo` (document offset 16 = 13 + 3).
    const edited = 'const x = 1;\nfood(bar);\n';
    highlighter.applyDocumentEdit(1, 16, 16, 'd', '', edited);
    expect(_layout(highlighter.semanticSpans)[1], ['0-4', '5-8']);
  });

  test('diffTexts finds the edit between two versions', () {
    final typed = diffTexts('foo(bar);', 'food(bar);');
    expect(
      (typed.start, typed.oldEnd, typed.inserted, typed.deleted),
      (3, 3, 'd', ''),
    );
    final replaced = diffTexts('let a = 1;', 'let abc = 12;');
    expect(
      (replaced.start, replaced.oldEnd, replaced.inserted, replaced.deleted),
      (5, 9, 'bc = 12', ' = 1'),
    );
    final same = diffTexts('x', 'x');
    expect((same.start, same.oldEnd, same.inserted), (1, 1, ''));
  });
}
