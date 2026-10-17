import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roxum/utils/vscode_theme.dart';

VsCodeTheme _theme(String tokenColors) =>
    VsCodeTheme.parse('{"colors": {}, "tokenColors": $tokenColors}');

void main() {
  test('parses VS Code colors, alpha last', () {
    expect(parseVsCodeColor('#E4E4E4EB'), const Color(0xEBE4E4E4));
    expect(parseVsCodeColor('#efb080'), const Color(0xFFEFB080));
    expect(parseVsCodeColor('#fff'), const Color(0xFFFFFFFF));
    expect(parseVsCodeColor('red'), isNull);
  });

  test('strips comments and trailing commas but not text inside strings', () {
    const source = '''{
      // a comment
      "url": "http://x.dev/*not a comment*/", /* block */
      "list": [1, 2,],
      "last": "a,", // trailing
    }''';
    expect(
      stripJsonComments(source).replaceAll(RegExp(r'\s'), ''),
      '{"url":"http://x.dev/*not a comment*/","list":[1,2],"last":"a,"}'
          .replaceAll(' ', ''),
    );
  });

  test('longest matching selector wins, then the later rule', () {
    final theme = _theme('''[
      {"scope": "entity.name", "settings": {"foreground": "#111111"}},
      {"scope": ["entity.name.function", "string"], "settings": {"foreground": "#222222"}},
      {"scope": "entity.name.function", "settings": {"foreground": "#333333"}},
      {"scope": "entity.name.functional", "settings": {"foreground": "#444444"}}
    ]''');
    expect(
      theme.resolve(['entity.name.function.tsx']).foreground,
      const Color(0xFF333333),
    );
    expect(
      theme.resolve(['entity.name.type']).foreground,
      const Color(0xFF111111),
    );
    expect(theme.resolve(['entity.names']).foreground, isNull);
  });

  test(
    'the deepest scope with a rule wins; parent selectors must match ancestors',
    () {
      final theme = _theme('''[
      {"scope": "meta.tag", "settings": {"foreground": "#111111"}},
      {"scope": "entity.name.tag.html", "settings": {"foreground": "#222222", "fontStyle": "bold"}},
      {"scope": "source.css entity.name.tag", "settings": {"foreground": "#333333"}}
    ]''');
      expect(
        theme.resolve(['meta.tag.tsx', 'entity.name.tag.tsx']).foreground,
        const Color(0xFF111111),
      );
      final html = theme.resolve(['meta.tag.html', 'entity.name.tag.html']);
      expect(html.foreground, const Color(0xFF222222));
      expect(html.toTextStyle().fontWeight, FontWeight.bold);
      expect(
        theme.resolve(['source.css', 'entity.name.tag.css']).foreground,
        const Color(0xFF333333),
      );
      expect(
        theme.resolve(['source.js', 'entity.name.tag.js']).foreground,
        isNull,
      );
    },
  );

  test('Cursor Dark gives each kind of name its own color', () {
    final theme = VsCodeTheme.parse(
      File('assets/themes/cursor-dark.json').readAsStringSync(),
    );
    final tsx = highlightThemeFromVsCode(theme, textMateLanguageFor('.tsx'));
    expect(tsx['root']!.backgroundColor, const Color(0xFF181818));
    expect(tsx['keyword']!.color, const Color(0xFF82D2CE));
    expect(tsx['string']!.color, const Color(0xFFE394DC));
    expect(tsx['title.function']!.color, const Color(0xFFEFB080));
    expect(tsx['property']!.color, const Color(0xFFAAA0FA));
    expect(tsx['number']!.color, const Color(0xFFEBC88D));
    expect(tsx['comment']!.fontStyle, FontStyle.italic);
    expect(tsx['tag']!.color, isNot(tsx['root']!.color));

    final html = highlightThemeFromVsCode(theme, textMateLanguageFor('.html'));
    expect(html['tag']!.color, const Color(0xFF87C3FF));
  });
}
