import 'package:code_forge/code_forge/completion.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _rank(
  List<String> labels,
  String prefix, {
  Map<String, String> sortText = const {},
  List<String> recent = const [],
}) => rankCompletions([
  for (final label in labels)
    RankInput(
      item: label,
      filterText: label,
      sortText: sortText[label] ?? '',
      recentIndex: recent.contains(label) ? recent.indexOf(label) : null,
    ),
], prefix);

void main() {
  group('fuzzyScore', () {
    test('finds useEffect from uEf, useEf and effect, but not ffect', () {
      for (final pattern in ['uEf', 'useEf', 'effect', 'ue', 'USEEFFECT']) {
        expect(fuzzyScore(pattern, 'useEffect'), isNotNull, reason: pattern);
      }
      expect(fuzzyScore('ffect', 'useEffect'), isNull);
      expect(fuzzyScore('fu', 'useEffect'), isNull);
    });

    test('prefers prefix, case and word-start matches', () {
      expect(
        fuzzyScore('use', 'useState')!,
        greaterThan(fuzzyScore('use', 'reuseItem') ?? -1 << 30),
      );
      expect(fuzzyScore('st', 'useState'), isNotNull);
      expect(fuzzyScore('st', 'pasta'), isNull);
      expect(
        fuzzyScore('St', 'useState')!,
        greaterThan(fuzzyScore('st', 'useState')!),
      );
    });
  });

  test('ranks by score, then recency, then sortText', () {
    expect(
      _rank(['useMemo', 'useEffect', 'useLayoutEffect', 'Effect'], 'uEf'),
      ['useEffect', 'useLayoutEffect'],
    );
    expect(
      _rank(
        ['user', 'useState', 'useEffect'],
        'use',
        sortText: {'user': '11', 'useState': '15', 'useEffect': '15'},
      ),
      ['user', 'useState', 'useEffect'],
    );
    expect(
      _rank(['useState', 'useEffect'], 'use', recent: ['useEffect']).first,
      'useEffect',
    );
  });

  group('parseSnippet', () {
    test('expands tab stops and placeholders in Tab order, ending at \$0', () {
      final s = parseSnippet(r'movieFinder(${1:query}, ${2:page})$0');
      expect(s.text, 'movieFinder(query, page)');
      expect(s.stops.map((t) => (t.index, s.text.substring(t.start, t.end))), [
        (1, 'query'),
        (2, 'page'),
        (0, ''),
      ]);
      expect(s.stops.last.start, s.text.length);
    });

    test('handles nesting, choices, variables, escapes and a missing \$0', () {
      final s = parseSnippet(
        r'${1:a ${2:b}} ${3|x,y|} ${TM_SELECTED_TEXT:sel}\$5 \}',
      );
      expect(s.text, r'a b x sel$5 }');
      expect(s.stops.map((t) => s.text.substring(t.start, t.end)), [
        'a b',
        'b',
        'x',
        '',
      ]);
      expect(s.stops.last.start, s.text.length);
      expect(
        parseSnippet(escapeSnippetText(r'cost: $5 {x}')).text,
        r'cost: $5 {x}',
      );
      final fromLocations = parseSnippet(
        snippetWithStops('if (\$a) {\n  \n}', [4, 12]),
      );
      expect(fromLocations.text, 'if (\$a) {\n  \n}');
      expect(fromLocations.stops.map((t) => t.start), [4, 12, 14]);
    });
  });

  test('closingTagFor closes opening tags only', () {
    expect(closingTagFor('  return <div className="a">'), '</div>');
    expect(closingTagFor('<button onClick={() => go(a > b)}>'), '</button>');
    expect(closingTagFor('<Foo.Bar>'), '</Foo.Bar>');
    expect(closingTagFor('(<>'), '</>');
    for (final line in [
      '<Foo />',
      '</div>',
      '<br>',
      'useState<string>',
      'const a = b<c>',
      '<a href="x>',
    ]) {
      expect(closingTagFor(line), isNull, reason: line);
    }
  });
}
