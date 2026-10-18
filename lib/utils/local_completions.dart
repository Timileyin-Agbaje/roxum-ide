// Suggestions computed in the app, without a language server, the way Acode
// (Ace) does it: keywords, words in the file, tags and properties, filtered as
// you type. They appear instantly and keep working when the TypeScript server
// is slow, stopped or killed for memory; the server's items are merged in.

import 'dart:io';

import 'package:code_forge/code_forge.dart';
import 'package:path/path.dart' as path;

enum _Kind {
  keyword,
  type,
  react,
  global,
  word,
  member,
  tag,
  attribute,
  cssProperty,
  cssValue,
  file,
  folder,
}

const _kindTypes = {
  _Kind.keyword: CompletionItemType.keyword,
  _Kind.type: CompletionItemType.interface,
  _Kind.react: CompletionItemType.function,
  _Kind.global: CompletionItemType.module,
  _Kind.word: CompletionItemType.text,
  _Kind.member: CompletionItemType.field,
  _Kind.tag: CompletionItemType.reference,
  _Kind.attribute: CompletionItemType.property,
  _Kind.cssProperty: CompletionItemType.property,
  _Kind.cssValue: CompletionItemType.value_,
  _Kind.file: CompletionItemType.file,
  _Kind.folder: CompletionItemType.folder,
};

const _kindDetails = {
  _Kind.keyword: 'keyword',
  _Kind.type: 'type',
  _Kind.react: 'React',
  _Kind.global: 'global',
  _Kind.word: 'in file',
  _Kind.member: 'member',
  _Kind.tag: 'tag',
  _Kind.attribute: 'attribute',
  _Kind.cssProperty: 'property',
  _Kind.cssValue: 'value',
  _Kind.file: 'file',
  _Kind.folder: 'folder',
};

// sortText decides ties after the fuzzy score: server items (sortText such as
// "11") first, then nearby words, then the fixed lists.
const _wordSort = '7', _listSort = '8';

const jsKeywords = [
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'from',
  'function',
  'if',
  'import',
  'in',
  'instanceof',
  'let',
  'new',
  'null',
  'of',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'undefined',
  'var',
  'void',
  'while',
  'yield',
];

const tsKeywords = [
  'abstract',
  'as',
  'declare',
  'enum',
  'implements',
  'interface',
  'keyof',
  'namespace',
  'private',
  'protected',
  'public',
  'readonly',
  'satisfies',
  'type',
];

const tsTypes = [
  'any',
  'Array',
  'bigint',
  'boolean',
  'Date',
  'Error',
  'Exclude',
  'Extract',
  'Map',
  'never',
  'NonNullable',
  'number',
  'object',
  'Omit',
  'Parameters',
  'Partial',
  'Pick',
  'Promise',
  'Readonly',
  'Record',
  'RegExp',
  'Required',
  'ReturnType',
  'Set',
  'string',
  'symbol',
  'unknown',
];

const reactApis = [
  'React',
  'useState',
  'useEffect',
  'useRef',
  'useMemo',
  'useCallback',
  'useContext',
  'useReducer',
  'useLayoutEffect',
  'useId',
  'useTransition',
  'useDeferredValue',
  'createContext',
  'forwardRef',
  'memo',
  'lazy',
  'Suspense',
  'Fragment',
  'StrictMode',
  'ReactNode',
  'FC',
  'ChangeEvent',
  'FormEvent',
  'MouseEvent',
];

const jsGlobals = [
  'console',
  'document',
  'window',
  'fetch',
  'JSON',
  'Math',
  'Object',
  'Number',
  'String',
  'Boolean',
  'setTimeout',
  'setInterval',
  'clearTimeout',
  'clearInterval',
  'localStorage',
  'sessionStorage',
  'navigator',
  'location',
  'alert',
  'parseInt',
  'parseFloat',
  'encodeURIComponent',
  'structuredClone',
  'URL',
  'URLSearchParams',
  'FormData',
  'AbortController',
  'process',
  'require',
  'module',
  'exports',
];

const commonMembers = [
  'log',
  'error',
  'warn',
  'info',
  'table',
  'map',
  'filter',
  'reduce',
  'forEach',
  'find',
  'findIndex',
  'some',
  'every',
  'includes',
  'indexOf',
  'push',
  'pop',
  'shift',
  'unshift',
  'slice',
  'splice',
  'concat',
  'join',
  'split',
  'trim',
  'toLowerCase',
  'toUpperCase',
  'replace',
  'replaceAll',
  'startsWith',
  'endsWith',
  'length',
  'keys',
  'values',
  'entries',
  'then',
  'catch',
  'finally',
  'json',
  'text',
  'stringify',
  'parse',
  'getElementById',
  'querySelector',
  'querySelectorAll',
  'addEventListener',
  'preventDefault',
  'stopPropagation',
  'target',
  'value',
  'current',
  'floor',
  'ceil',
  'round',
  'random',
  'max',
  'min',
  'abs',
  'toFixed',
  'toString',
  'now',
  'sort',
  'at',
];

const htmlTags = [
  'a',
  'article',
  'aside',
  'audio',
  'b',
  'blockquote',
  'body',
  'br',
  'button',
  'canvas',
  'code',
  'dialog',
  'div',
  'em',
  'fieldset',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'head',
  'header',
  'hr',
  'html',
  'i',
  'iframe',
  'img',
  'input',
  'label',
  'li',
  'link',
  'main',
  'meta',
  'nav',
  'ol',
  'option',
  'p',
  'pre',
  'script',
  'section',
  'select',
  'small',
  'span',
  'strong',
  'style',
  'svg',
  'table',
  'tbody',
  'td',
  'textarea',
  'th',
  'thead',
  'title',
  'tr',
  'ul',
  'video',
];

const jsxProps = [
  'className',
  'onClick',
  'onChange',
  'onSubmit',
  'onInput',
  'onKeyDown',
  'onFocus',
  'onBlur',
  'key',
  'ref',
  'style',
  'id',
  'href',
  'src',
  'alt',
  'type',
  'value',
  'placeholder',
  'disabled',
  'checked',
  'name',
  'htmlFor',
  'children',
  'title',
  'target',
  'rel',
  'width',
  'height',
  'required',
];

const htmlAttributes = [
  'class',
  'id',
  'href',
  'src',
  'alt',
  'type',
  'value',
  'placeholder',
  'disabled',
  'checked',
  'name',
  'for',
  'style',
  'title',
  'target',
  'rel',
  'width',
  'height',
  'onclick',
  'action',
  'method',
  'lang',
  'charset',
  'content',
  'required',
];

const cssProperties = [
  'align-content',
  'align-items',
  'align-self',
  'animation',
  'aspect-ratio',
  'backdrop-filter',
  'background',
  'background-color',
  'background-image',
  'background-position',
  'background-size',
  'border',
  'border-bottom',
  'border-color',
  'border-left',
  'border-radius',
  'border-right',
  'border-top',
  'border-width',
  'bottom',
  'box-shadow',
  'box-sizing',
  'color',
  'column-gap',
  'content',
  'cursor',
  'display',
  'filter',
  'flex',
  'flex-basis',
  'flex-direction',
  'flex-grow',
  'flex-shrink',
  'flex-wrap',
  'font',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'gap',
  'grid',
  'grid-area',
  'grid-column',
  'grid-row',
  'grid-template-columns',
  'grid-template-rows',
  'height',
  'inset',
  'justify-content',
  'justify-items',
  'left',
  'letter-spacing',
  'line-height',
  'list-style',
  'margin',
  'margin-bottom',
  'margin-left',
  'margin-right',
  'margin-top',
  'max-height',
  'max-width',
  'min-height',
  'min-width',
  'object-fit',
  'opacity',
  'outline',
  'overflow',
  'overflow-x',
  'overflow-y',
  'padding',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'padding-top',
  'place-items',
  'pointer-events',
  'position',
  'right',
  'row-gap',
  'text-align',
  'text-decoration',
  'text-overflow',
  'text-transform',
  'top',
  'transform',
  'transition',
  'user-select',
  'vertical-align',
  'visibility',
  'white-space',
  'width',
  'word-break',
  'z-index',
];

const cssValues = [
  'absolute',
  'auto',
  'block',
  'bold',
  'center',
  'column',
  'contain',
  'cover',
  'dashed',
  'ease',
  'ease-in-out',
  'fixed',
  'flex',
  'flex-end',
  'flex-start',
  'grid',
  'hidden',
  'inherit',
  'initial',
  'inline',
  'inline-block',
  'italic',
  'linear',
  'none',
  'normal',
  'nowrap',
  'pointer',
  'relative',
  'row',
  'scroll',
  'solid',
  'space-around',
  'space-between',
  'space-evenly',
  'sticky',
  'stretch',
  'transparent',
  'uppercase',
  'visible',
  'wrap',
];

/// Builds the in-app suggestions for one file. [call] runs on every
/// keystroke, so it only scans text near the cursor and allocates little.
class LocalCompletions {
  final String filePath;
  final String _ext;
  final Map<String, LspCompletion> _fixed = {};

  LocalCompletions(this.filePath)
    : _ext = path.extension(filePath).toLowerCase();

  static bool supports(String filePath) => const {
    '.ts',
    '.tsx',
    '.js',
    '.jsx',
    '.mjs',
    '.cjs',
    '.mts',
    '.cts',
    '.html',
    '.htm',
    '.css',
  }.contains(path.extension(filePath).toLowerCase());

  bool get _isCss => _ext == '.css';
  bool get _isHtml => _ext == '.html' || _ext == '.htm';
  bool get _isJsx => _ext == '.tsx' || _ext == '.jsx';
  bool get _isTs => const {'.ts', '.tsx', '.mts', '.cts'}.contains(_ext);

  /// Only this much text around the cursor is scanned for words.
  static const _window = 20000;

  List<LspCompletion> call(String text, int cursor, String prefix) {
    if (cursor > text.length) return const [];
    final lineStart = text.lastIndexOf('\n', cursor - 1) + 1;
    final beforeWord = text.substring(lineStart, cursor - prefix.length);

    if (!_isCss && !_isHtml) {
      final importPath = RegExp(
        r'''(?:from\s+|import\s*\(\s*|require\s*\(\s*|import\s+)['"]([^'"]*)$''',
      ).firstMatch(beforeWord);
      if (importPath != null) return _paths(importPath.group(1)!);
      if (_inString(beforeWord)) return _words(text, cursor, prefix);
    }

    if (_isCss) {
      final afterColon = RegExp(r':[^;{}]*$').hasMatch(beforeWord);
      return [
        ..._cssItems(
          text,
          cursor,
          lineStart,
          afterColon ? cssValues : cssProperties,
          afterColon ? _Kind.cssValue : _Kind.cssProperty,
          prefix,
        ),
        ..._words(text, cursor, prefix),
      ];
    }

    final trimmed = beforeWord.trimRight();
    if (beforeWord.endsWith('<') || beforeWord.endsWith('</')) {
      if (!(_isJsx || _isHtml)) return _words(text, cursor, prefix);
      return [
        ..._list(htmlTags, _Kind.tag, prefix),
        if (_isJsx)
          ..._words(
            text,
            cursor,
            prefix,
          ).where((w) => w.label.startsWith(RegExp('[A-Z]'))),
      ];
    }
    if ((_isJsx || _isHtml) && _inOpeningTag(beforeWord)) {
      return [
        ..._list(_isHtml ? htmlAttributes : jsxProps, _Kind.attribute, prefix),
        ..._words(text, cursor, prefix),
      ];
    }
    if (_isHtml) return _words(text, cursor, prefix);

    if (trimmed.endsWith('.')) {
      return [
        ..._list(commonMembers, _Kind.member, prefix),
        ..._words(text, cursor, prefix, membersOnly: true),
      ];
    }
    return [
      ..._list(jsKeywords, _Kind.keyword, prefix),
      if (_isTs) ..._list(tsKeywords, _Kind.keyword, prefix),
      if (_isTs) ..._list(tsTypes, _Kind.type, prefix),
      ..._list(reactApis, _Kind.react, prefix),
      ..._list(jsGlobals, _Kind.global, prefix),
      ..._words(text, cursor, prefix),
    ];
  }

  /// Whether the first letter of [prefix] occurs in [word], which every fuzzy
  /// match needs; skips most candidates before allocating anything.
  static bool _mayMatch(String word, String prefix) =>
      prefix.isEmpty || word.toLowerCase().contains(prefix[0].toLowerCase());

  List<LspCompletion> _list(List<String> labels, _Kind kind, String prefix) => [
    for (final label in labels)
      if (_mayMatch(label, prefix))
        _fixed.putIfAbsent('$kind:$label', () => _item(label, kind, _listSort)),
  ];

  static LspCompletion _item(
    String label,
    _Kind kind,
    String sortText, {
    String? insertText,
  }) => LspCompletion(
    label: label,
    itemType: _kindTypes[kind]!,
    completionItem: {
      'label': label,
      // Not from the server: nothing to resolve, no documentation panel.
      'localOnly': true,
      'detail': _kindDetails[kind],
      'sortText': sortText,
      'insertText': ?insertText,
    },
  );

  /// CSS names contain '-', which isn't part of the typed word, so these
  /// replace the whole hyphenated word before the cursor.
  List<LspCompletion> _cssItems(
    String text,
    int cursor,
    int lineStart,
    List<String> labels,
    _Kind kind,
    String prefix,
  ) {
    final typed = RegExp(r'[A-Za-z-]*$')
        .firstMatch(text.substring(lineStart, cursor))!;
    final line = '\n'.allMatches(text.substring(0, lineStart)).length;
    final range = {
      'start': {'line': line, 'character': typed.start},
      'end': {'line': line, 'character': cursor - lineStart},
    };
    return [
      for (final label in labels)
        if (_mayMatch(label, prefix))
          LspCompletion(
            label: label,
            itemType: _kindTypes[kind]!,
            completionItem: {
              'label': label,
              // Not from the server: nothing to resolve, no documentation panel.
              'localOnly': true,
              'detail': _kindDetails[kind],
              'sortText': _listSort,
              'textEdit': {'range': range, 'newText': label},
            },
          ),
    ];
  }

  /// Words in the text near the cursor, nearest first; the word being typed
  /// isn't suggested unless it also appears elsewhere.
  List<LspCompletion> _words(
    String text,
    int cursor,
    String prefix, {
    bool membersOnly = false,
  }) {
    final start = (cursor - _window).clamp(0, text.length);
    final end = (cursor + _window).clamp(0, text.length);
    final pattern = membersOnly
        ? RegExp(r'\.([A-Za-z_$][\w$]+)')
        : RegExp(r'[A-Za-z_$][\w$]+');
    final distances = <String, int>{};
    final counts = <String, int>{};
    for (final match in pattern.allMatches(text.substring(start, end))) {
      final word = membersOnly ? match.group(1)! : match.group(0)!;
      if (!_mayMatch(word, prefix)) continue;
      final distance = (start + match.start - cursor).abs();
      counts[word] = (counts[word] ?? 0) + 1;
      final previous = distances[word];
      if (previous == null || distance < previous) distances[word] = distance;
    }
    if (counts[prefix] == 1) distances.remove(prefix);
    return [
      for (final MapEntry(key: word, value: distance) in distances.entries)
        _item(
          word,
          membersOnly ? _Kind.member : _Kind.word,
          '$_wordSort${distance.toString().padLeft(7, '0')}',
        ),
    ];
  }

  /// Files and folders for a relative import being typed ("./comp" lists
  /// the file's folder). Script extensions are left out, as imports do.
  List<LspCompletion> _paths(String typed) {
    if (!typed.startsWith('.')) return const [];
    final slash = typed.lastIndexOf('/');
    final dir = Directory(
      path.normalize(
        path.join(
          path.dirname(filePath),
          slash < 0 ? '.' : typed.substring(0, slash),
        ),
      ),
    );
    try {
      return [
        for (final entity in dir.listSync())
          if (!path.basename(entity.path).startsWith('.') &&
              path.basename(entity.path) != 'node_modules')
            entity is Directory
                ? _item(path.basename(entity.path), _Kind.folder, _listSort)
                : _item(
                    const {
                          '.ts',
                          '.tsx',
                          '.js',
                          '.jsx',
                        }.contains(path.extension(entity.path))
                        ? path.basenameWithoutExtension(entity.path)
                        : path.basename(entity.path),
                    _Kind.file,
                    _listSort,
                  ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static bool _inString(String lineBeforeWord) {
    String? quote;
    for (var i = 0; i < lineBeforeWord.length; i++) {
      final char = lineBeforeWord[i];
      if (quote != null) {
        if (char == r'\') {
          i++;
        } else if (char == quote) {
          quote = null;
        }
      } else if (char == '"' || char == "'" || char == '`') {
        quote = char;
      }
    }
    return quote != null;
  }

  /// Inside `<tag ...` on this line (an attribute or prop name goes here).
  static bool _inOpeningTag(String lineBeforeWord) {
    final open = lineBeforeWord.lastIndexOf('<');
    if (open < 0 || lineBeforeWord.lastIndexOf('>') > open) return false;
    return RegExp(r'^<[A-Za-z][\w.:-]*\s')
            .hasMatch(lineBeforeWord.substring(open)) &&
        !_inString(lineBeforeWord.substring(open)) &&
        '{'.allMatches(lineBeforeWord.substring(open)).length ==
            '}'.allMatches(lineBeforeWord.substring(open)).length;
  }
}
