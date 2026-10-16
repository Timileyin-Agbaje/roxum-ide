import 'dart:convert';

import 'package:flutter/painting.dart';

/// A VS Code color theme (`colors`, `tokenColors`, `semanticTokenColors`).
class VsCodeTheme {
  final String name;
  final Map<String, Color> colors;
  final List<TokenRule> rules;
  final Map<String, dynamic> semanticTokenColors;

  VsCodeTheme({
    required this.name,
    required this.colors,
    required this.rules,
    required this.semanticTokenColors,
  });

  /// Parses theme JSON. VS Code allows comments and trailing commas in it.
  factory VsCodeTheme.parse(String source) {
    final json = jsonDecode(stripJsonComments(source)) as Map<String, dynamic>;
    final colors = <String, Color>{};
    (json['colors'] as Map<String, dynamic>? ?? {}).forEach((key, value) {
      final color = value is String ? parseVsCodeColor(value) : null;
      if (color != null) colors[key] = color;
    });
    final rules = <TokenRule>[];
    for (final entry in json['tokenColors'] as List? ?? const []) {
      if (entry is! Map) continue;
      final settings = entry['settings'];
      if (settings is! Map) continue;
      final foreground = settings['foreground'] is String ? parseVsCodeColor(settings['foreground']) : null;
      final fontStyle = settings['fontStyle'] is String ? settings['fontStyle'] as String : null;
      if (foreground == null && fontStyle == null) continue;
      final scope = entry['scope'];
      final selectors = scope is String ? [scope] : scope is List ? scope.whereType<String>() : const <String>[];
      for (final selector in selectors.expand((s) => s.split(','))) {
        final parts = selector.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && p != '>').toList();
        if (parts.isEmpty || parts.any((p) => p.startsWith('-'))) continue;
        rules.add(TokenRule(parts, foreground, fontStyle));
      }
    }
    return VsCodeTheme(
      name: json['name'] as String? ?? '',
      colors: colors,
      rules: rules,
      semanticTokenColors: Map<String, dynamic>.from(json['semanticTokenColors'] as Map? ?? {}),
    );
  }

  Color color(String key, Color fallback) => colors[key] ?? fallback;

  /// [color] drawn over [background], for translucent theme colors used as solid fills.
  Color solid(String key, Color background) => Color.alphaBlend(colors[key] ?? const Color(0x00000000), background);

  /// Resolves a scope stack (outermost first) the way VS Code does: each property comes
  /// from the deepest scope that a rule matches; among rules for the same scope, the
  /// longest selector wins, then the one with more parent scopes, then the later one.
  TokenStyle resolve(List<String> scopes) {
    Color? foreground;
    String? fontStyle;
    for (var depth = scopes.length - 1; depth >= 0; depth--) {
      foreground ??= _best(scopes, depth, (r) => r.foreground != null)?.foreground;
      fontStyle ??= _best(scopes, depth, (r) => r.fontStyle != null)?.fontStyle;
      if (foreground != null && fontStyle != null) break;
    }
    return TokenStyle(foreground, fontStyle);
  }

  TokenRule? _best(List<String> scopes, int depth, bool Function(TokenRule) has) {
    TokenRule? best;
    for (final rule in rules) {
      if (!has(rule) || !_scopeMatches(rule.parts.last, scopes[depth])) continue;
      if (!_parentsMatch(rule.parts, scopes, depth)) continue;
      if (best == null || _compare(rule, best) >= 0) best = rule;
    }
    return best;
  }

  static int _compare(TokenRule a, TokenRule b) {
    final byLength = a.parts.last.length.compareTo(b.parts.last.length);
    if (byLength != 0) return byLength;
    return a.parts.length.compareTo(b.parts.length);
  }

  static bool _parentsMatch(List<String> parts, List<String> scopes, int depth) {
    var scopeIndex = depth - 1;
    for (var i = parts.length - 2; i >= 0; i--) {
      while (scopeIndex >= 0 && !_scopeMatches(parts[i], scopes[scopeIndex])) {
        scopeIndex--;
      }
      if (scopeIndex < 0) return false;
      scopeIndex--;
    }
    return true;
  }

  static bool _scopeMatches(String selector, String scope) =>
      scope == selector || (scope.startsWith(selector) && scope.codeUnitAt(selector.length) == 0x2E);
}

class TokenRule {
  final List<String> parts;
  final Color? foreground;
  final String? fontStyle;
  TokenRule(this.parts, this.foreground, this.fontStyle);
}

class TokenStyle {
  final Color? foreground;
  final String? fontStyle;
  const TokenStyle(this.foreground, this.fontStyle);

  bool get isEmpty => foreground == null && (fontStyle == null || fontStyle!.trim().isEmpty);

  TextStyle toTextStyle() {
    final styles = (fontStyle ?? '').split(' ');
    return TextStyle(
      color: foreground,
      fontWeight: styles.contains('bold') ? FontWeight.bold : null,
      fontStyle: styles.contains('italic') ? FontStyle.italic : null,
      decoration: styles.contains('underline') ? TextDecoration.underline : null,
    );
  }
}

/// Parses `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`.
Color? parseVsCodeColor(String value) {
  var hex = value.trim();
  if (!hex.startsWith('#')) return null;
  hex = hex.substring(1);
  if (hex.length == 3 || hex.length == 4) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) hex = '${hex}ff';
  if (hex.length != 8) return null;
  final rgba = int.tryParse(hex, radix: 16);
  if (rgba == null) return null;
  return Color(((rgba & 0xff) << 24) | (rgba >> 8));
}

/// Removes `//` and `/* */` comments, then trailing commas, outside strings.
String stripJsonComments(String source) {
  final withoutComments = _outsideStrings(source, (text, i) {
    if (text.startsWith('//', i)) {
      final end = text.indexOf('\n', i);
      return end < 0 ? text.length : end;
    }
    if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      return end < 0 ? text.length : end + 2;
    }
    return null;
  });
  return _outsideStrings(withoutComments, (text, i) {
    if (text[i] != ',') return null;
    var j = i + 1;
    while (j < text.length && ' \t\r\n'.contains(text[j])) {
      j++;
    }
    return j >= text.length || text[j] == '}' || text[j] == ']' ? i + 1 : null;
  });
}

/// Copies [source], letting [skip] drop text outside string literals: it returns the index
/// to continue from, or null to keep the character at `i`.
String _outsideStrings(String source, int? Function(String text, int i) skip) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    if (source[i] == '"') {
      final start = i++;
      while (i < source.length && source[i] != '"') {
        i += source[i] == r'\' ? 2 : 1;
      }
      i = i < source.length ? i + 1 : source.length;
      out.write(source.substring(start, i));
      continue;
    }
    final next = skip(source, i);
    if (next != null) {
      i = next;
    } else {
      out.write(source[i++]);
    }
  }
  return out.toString();
}

/// The TextMate root scope and scope suffix VS Code uses for a language.
class TextMateLanguage {
  final String rootScope;
  final String suffix;
  final bool isMarkup;
  const TextMateLanguage(this.rootScope, this.suffix, {this.isMarkup = false});
}

TextMateLanguage? textMateLanguageFor(String extension) => switch (extension.toLowerCase()) {
  '.ts' || '.mts' || '.cts' => const TextMateLanguage('source.ts', 'ts'),
  '.tsx' => const TextMateLanguage('source.tsx', 'tsx', isMarkup: true),
  '.js' || '.mjs' || '.cjs' => const TextMateLanguage('source.js', 'js'),
  '.jsx' => const TextMateLanguage('source.js.jsx', 'js.jsx', isMarkup: true),
  '.html' || '.htm' => const TextMateLanguage('text.html.basic', 'html', isMarkup: true),
  '.css' => const TextMateLanguage('source.css', 'css'),
  _ => null,
};

/// highlight.js scope -> TextMate scopes (outermost first) that VS Code would give the same text.
const _highlightScopes = <String, List<String>>{
  'keyword': ['keyword'],
  'built_in': ['support.function'],
  'type': ['entity.name.type'],
  'literal': ['constant.language'],
  'number': ['constant.numeric'],
  'string': ['string'],
  'meta-string': ['string'],
  'subst': ['meta.template.expression'],
  'regexp': ['string.regexp'],
  'title': ['entity.name'],
  'title.function': ['entity.name.function'],
  'title.function.invoke': ['entity.name.function'],
  'title.class': ['entity.name.type.class'],
  'title.class.inherited': ['entity.other.inherited-class'],
  'attr': ['meta.object-literal.key'],
  'property': ['variable.other.property'],
  'params': ['variable.parameter'],
  'variable': ['variable'],
  'variable.constant': ['variable.other.constant'],
  'variable.language': ['variable.language'],
  'comment': ['comment'],
  'doctag': ['comment.block.documentation', 'storage.type.class.jsdoc'],
  'tag': ['meta.tag', 'entity.name.tag'],
  'name': ['meta.tag', 'entity.name.tag'],
  // CSS property names; highlight.js uses `attribute` only in CSS here.
  'attribute': ['meta.property-name', 'support.type.property-name'],
  'symbol': ['constant.character.entity'],
  'meta': ['meta.preprocessor'],
  'operator': ['keyword.operator'],
  'punctuation': ['punctuation'],
  'selector-tag': ['entity.name.tag'],
  'selector-id': ['entity.other.attribute-name.id'],
  'selector-class': ['entity.other.attribute-name.class'],
  'selector-attr': ['entity.other.attribute-name'],
  'selector-pseudo': ['entity.other.attribute-name.pseudo-class'],
};

/// In HTML and JSX, highlight.js marks tag attributes as `attr`, which elsewhere means object keys.
const _markupAttrScopes = ['meta.tag', 'entity.other.attribute-name'];

/// A highlight.js theme map (as used by re_highlight and code_forge) built from [theme].
/// Keys without a matching rule are left out, so they use the editor foreground.
Map<String, TextStyle> highlightThemeFromVsCode(VsCodeTheme theme, [TextMateLanguage? language]) {
  List<String> withLanguage(List<String> scopes) => [
    if (language != null) language.rootScope,
    for (final scope in scopes) language == null ? scope : '$scope.${language.suffix}',
  ];

  final result = <String, TextStyle>{
    'root': TextStyle(
      color: theme.color('editor.foreground', const Color(0xffe4e4e4)),
      backgroundColor: theme.color('editor.background', const Color(0xff181818)),
    ),
  };
  _highlightScopes.forEach((key, scopes) {
    final effective = key == 'attr' && (language?.isMarkup ?? false) ? _markupAttrScopes : scopes;
    final style = theme.resolve(withLanguage(effective));
    if (!style.isEmpty) result[key] = style.toTextStyle();
  });
  return result;
}
