import 'package:flutter_test/flutter_test.dart';
import 'package:roxum/utils/local_completions.dart';

List<String> _labels(LocalCompletions c, String text, {String prefix = ''}) => [
  for (final item in c(text, text.length, prefix)) item.label,
];

void main() {
  final tsx = LocalCompletions('/p/src/App.tsx');

  test('offers keywords, React, types and words from the file', () {
    const text =
        'const [movies, setMovies] = useState([]);\nfunction handleSearch() {}\nhan';
    final labels = _labels(tsx, text, prefix: 'han');
    expect(labels, contains('handleSearch'));
    expect(labels, isNot(contains('han')), reason: 'the word being typed');
    expect(
      _labels(tsx, 'use', prefix: 'use'),
      containsAll(['useState', 'useEffect']),
    );
    expect(
      _labels(tsx, 'con', prefix: 'con'),
      containsAll(['const', 'console']),
    );
    expect(_labels(tsx, 'str', prefix: 'str'), contains('string'));
  });

  test('knows JSX tags, components, props and members', () {
    const component = 'function MovieCard() {}\nreturn <';
    expect(
      _labels(tsx, component),
      containsAll(['div', 'button', 'MovieCard']),
    );
    expect(_labels(tsx, '<button onC', prefix: 'onC'), contains('onClick'));
    expect(_labels(tsx, 'items.ma', prefix: 'ma'), contains('map'));
    expect(_labels(tsx, 'items.ma', prefix: 'ma'), isNot(contains('const')));
  });

  test('only file words inside strings; CSS properties and values', () {
    expect(
      _labels(tsx, "const s = 'con", prefix: 'con'),
      isNot(contains('console')),
    );
    final css = LocalCompletions('/p/src/App.css');
    final properties = css('.a { background-co', 18, 'co');
    final color = properties.firstWhere((i) => i.label == 'background-color');
    expect(
      (color.completionItem['textEdit'] as Map)['range']['start']['character'],
      5,
    );
    expect(_labels(css, '.a { display: fl', prefix: 'fl'), contains('flex'));
  });
}
