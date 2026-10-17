/// Pure helpers for code completion: fuzzy matching, ranking, LSP snippets
/// and JSX closing tags.
library;

import 'dart:math' as math;

const _minScore = -(1 << 30);

/// Scores [pattern] against [word] the way VS Code's suggest widget does,
/// or returns null when they don't match.
///
/// All pattern characters must appear in order (ignoring case), and the
/// first one must match at a strong position: the start of the word, a
/// camelCase hump or after a separator. Higher is better: bonuses for strong
/// positions, consecutive characters, matching case and a whole-prefix match.
/// So `uEf`, `useEf` and `effect` all find `useEffect`, but `ffect` doesn't.
int? fuzzyScore(String pattern, String word) {
  final patternLength = pattern.length, wordLength = word.length;
  if (patternLength == 0) return 0;
  if (patternLength > wordLength) return null;
  final lowerPattern = pattern.toLowerCase();
  final lowerWord = word.toLowerCase();

  var matched = 0;
  for (var j = 0; j < wordLength && matched < patternLength; j++) {
    if (lowerWord.codeUnitAt(j) == lowerPattern.codeUnitAt(matched)) {
      matched++;
    }
  }
  if (matched < patternLength) return null;

  // previous[j]: best score with the previous pattern character at word[j].
  var previous = List<int>.filled(wordLength, _minScore);
  for (var i = 0; i < patternLength; i++) {
    final current = List<int>.filled(wordLength, _minScore);
    var bestBeforeGap = _minScore;
    for (var j = i; j < wordLength; j++) {
      if (i > 0 && j >= 2) {
        bestBeforeGap = math.max(bestBeforeGap, previous[j - 2]);
      }
      if (lowerWord.codeUnitAt(j) != lowerPattern.codeUnitAt(i)) continue;
      final strong = _isStrongPosition(word, j);
      if (i == 0 && !strong) continue;
      final score =
          1 +
          (strong ? (j == 0 ? 8 : 6) : 0) +
          (word.codeUnitAt(j) == pattern.codeUnitAt(i) ? 1 : 0);
      if (i == 0) {
        current[j] = score;
        continue;
      }
      final consecutive = previous[j - 1] == _minScore
          ? _minScore
          : previous[j - 1] + 5;
      final best = math.max(consecutive, bestBeforeGap);
      if (best != _minScore) current[j] = best + score;
    }
    previous = current;
  }

  final best = previous.reduce(math.max);
  if (best == _minScore) return null;
  return lowerWord.startsWith(lowerPattern) ? best + 20 : best;
}

bool _isStrongPosition(String word, int index) {
  if (index == 0) return true;
  final previous = word[index - 1];
  if ('_-./\\\$: '.contains(previous)) return true;
  final char = word[index];
  return _isUpper(char) && !_isUpper(previous);
}

bool _isUpper(String char) =>
    char.toUpperCase() == char && char.toLowerCase() != char;

/// A completion candidate for [rankCompletions].
class RankInput<T> {
  final T item;
  final String filterText;
  final String sortText;
  final bool preselect;

  /// 0 for the most recently accepted item, 1 for the one before, ...;
  /// null if it wasn't accepted recently.
  final int? recentIndex;

  const RankInput({
    required this.item,
    required this.filterText,
    required this.sortText,
    this.preselect = false,
    this.recentIndex,
  });
}

/// Filters [candidates] by [prefix] and orders them: fuzzy score (with a
/// boost for recently accepted items) first, then preselect, the server's
/// sortText, shorter text and alphabetical order.
List<T> rankCompletions<T>(List<RankInput<T>> candidates, String prefix) {
  final scored = <({RankInput<T> input, int score})>[];
  for (final candidate in candidates) {
    final score = fuzzyScore(prefix, candidate.filterText);
    if (score == null) continue;
    final recent = candidate.recentIndex;
    final boost = recent == null ? 0 : math.max(1, 8 - recent ~/ 7);
    scored.add((input: candidate, score: score + boost));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    if (a.input.preselect != b.input.preselect) {
      return a.input.preselect ? -1 : 1;
    }
    final bySortText = a.input.sortText.compareTo(b.input.sortText);
    if (bySortText != 0) return bySortText;
    final byLength = a.input.filterText.length.compareTo(
      b.input.filterText.length,
    );
    if (byLength != 0) return byLength;
    return a.input.filterText.compareTo(b.input.filterText);
  });
  return [for (final entry in scored) entry.input.item];
}

/// Remembers the last accepted completions per language, most recent first.
class CompletionRecency {
  static const maxEntries = 50;
  final Map<String, List<String>> _byLanguage = {};

  /// Called after each change, for example to save [toJson].
  void Function()? onChanged;

  int? indexOf(String language, String label) {
    final index = _byLanguage[language]?.indexOf(label) ?? -1;
    return index < 0 ? null : index;
  }

  void record(String language, String label) {
    final labels = _byLanguage.putIfAbsent(language, () => []);
    labels
      ..remove(label)
      ..insert(0, label);
    if (labels.length > maxEntries) {
      labels.removeRange(maxEntries, labels.length);
    }
    onChanged?.call();
  }

  Map<String, List<String>> toJson() => _byLanguage;

  void load(Map<String, dynamic> json) {
    _byLanguage.clear();
    json.forEach((language, labels) {
      if (labels is List) {
        _byLanguage[language] = labels
            .whereType<String>()
            .take(maxEntries)
            .toList();
      }
    });
  }
}

/// A tab stop in an expanded snippet: [start]..[end] is its placeholder text.
typedef SnippetStop = ({int index, int start, int end});

/// Expands an LSP snippet (`$1`, `${1:name}`, `${1|a,b|}`, `$0`, variables)
/// into plain text and its tab stops, in the order Tab visits them: 1, 2, ...
/// then 0 (added at the end of the text if the snippet has none).
({String text, List<SnippetStop> stops}) parseSnippet(String snippet) {
  final out = StringBuffer();
  final stops = <int, SnippetStop>{};
  final placeholders = <int, String>{};
  var i = 0;

  int? readInt() {
    final start = i;
    while (i < snippet.length && _isDigit(snippet.codeUnitAt(i))) {
      i++;
    }
    return i > start ? int.parse(snippet.substring(start, i)) : null;
  }

  String? readName() {
    final start = i;
    while (i < snippet.length && _isNameChar(snippet.codeUnitAt(i))) {
      i++;
    }
    return i > start ? snippet.substring(start, i) : null;
  }

  void addStop(int index, int start) {
    stops.putIfAbsent(
      index,
      () => (index: index, start: start, end: out.length),
    );
    placeholders.putIfAbsent(index, () => out.toString().substring(start));
  }

  // Parses until an unescaped [terminator] (or the end), writing text to out.
  void parse(String? terminator) {
    while (i < snippet.length) {
      final char = snippet[i];
      if (terminator != null && char == terminator) return;
      if (char == r'\' && i + 1 < snippet.length) {
        out.write(snippet[i + 1]);
        i += 2;
        continue;
      }
      if (char != r'$' || i + 1 >= snippet.length) {
        out.write(char);
        i++;
        continue;
      }
      i++;
      if (snippet[i] == '{') {
        final braceStart = i;
        i++;
        final index = readInt();
        final name = index == null ? readName() : null;
        if (index == null && name == null) {
          i = braceStart;
          out.write(r'$');
          continue;
        }
        final start = out.length;
        if (i < snippet.length && snippet[i] == ':') {
          i++;
          parse('}');
        } else if (index != null && i < snippet.length && snippet[i] == '|') {
          i++;
          final choiceEnd = snippet.indexOf('|}', i);
          final choices = snippet.substring(
            i,
            choiceEnd < 0 ? snippet.length : choiceEnd,
          );
          out.write(choices.split(',').first);
          i = choiceEnd < 0 ? snippet.length : choiceEnd + 1;
        } else if (name != null && i < snippet.length && snippet[i] == '/') {
          // Variable transforms aren't supported; the variable is empty.
          final close = snippet.indexOf('}', i);
          i = close < 0 ? snippet.length : close;
        } else if (index != null && placeholders[index] != null) {
          out.write(placeholders[index]);
        }
        if (i < snippet.length && snippet[i] == '}') i++;
        if (index != null) addStop(index, start);
      } else {
        final index = readInt();
        if (index != null) {
          final start = out.length;
          if (placeholders[index] != null) out.write(placeholders[index]);
          addStop(index, start);
        } else if (readName() == null) {
          out.write(r'$');
        }
      }
    }
  }

  parse(null);
  final text = out.toString();
  final ordered = stops.values.where((s) => s.index > 0).toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  ordered.add(stops[0] ?? (index: 0, start: text.length, end: text.length));
  return (text: text, stops: ordered);
}

bool _isDigit(int code) => code >= 48 && code <= 57;

bool _isNameChar(int code) =>
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    _isDigit(code) ||
    code == 95;

/// Escapes text so [parseSnippet] returns it unchanged.
String escapeSnippetText(String text) =>
    text.replaceAllMapped(RegExp(r'[\\$}]'), (m) => '\\${m[0]}');

const _voidTags = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// The closing tag to insert after typing `>` at the end of [textBeforeCursor]
/// (which includes that `>`; it may span lines), or null if it doesn't close
/// an opening tag: `<div className="a">` gives `</div>`, `<>` gives `</>`,
/// while self-closing tags, void HTML tags, closing tags, generics like
/// `useState<string>` and tags inside strings or `//` comments give null.
///
/// HTML tag names ignore case ([isHtml]); in JSX a capitalized name is a
/// component, which is never void.
String? closingTagFor(String textBeforeCursor, {bool isHtml = false}) {
  if (!textBeforeCursor.endsWith('>')) return null;
  final end = textBeforeCursor.length - 1;
  for (
    var start = textBeforeCursor.lastIndexOf('<', end - 1);
    start >= 0;
    start = start == 0 ? -1 : textBeforeCursor.lastIndexOf('<', start - 1)
  ) {
    final name = _openingTagName(textBeforeCursor, start, end);
    if (name == null) continue;
    if (_inStringOrLineComment(textBeforeCursor, start)) return null;
    // Lowercase names are HTML elements; capitalized ones (<Input>) are
    // components and always need a closing tag.
    final isElement = isHtml || name == name.toLowerCase();
    if (isElement && _voidTags.contains(name.toLowerCase())) return null;
    return '</$name>';
  }
  return null;
}

/// Whether [index] follows an unclosed quote or `//` on its line. JSX text
/// with an apostrophe before the tag also counts; that only means no closing
/// tag is added.
bool _inStringOrLineComment(String text, int index) {
  final lineStart = text.lastIndexOf('\n', index) + 1;
  String? quote;
  for (var i = lineStart; i < index; i++) {
    final char = text[i];
    if (quote != null) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == '"' || char == "'" || char == '`') {
      quote = char;
    } else if (char == '/' && i + 1 < index && text[i + 1] == '/') {
      return true;
    }
  }
  return quote != null;
}

/// The tag name if `<` at [start] opens a tag that ends with the `>` at [end].
String? _openingTagName(String line, int start, int end) {
  if (start > 0) {
    final before = line.codeUnitAt(start - 1);
    // An identifier, `)` or `]` before `<` means a generic or a comparison.
    if (_isNameChar(before) || before == 36 || before == 41 || before == 93) {
      return null;
    }
  }
  var i = start + 1;
  final nameStart = i;
  while (i < end) {
    final code = line.codeUnitAt(i);
    if (!(_isNameChar(code) || code == 46 || code == 58 || code == 45)) break;
    i++;
  }
  final name = line.substring(nameStart, i);
  if (name.isNotEmpty && !_isLetter(name.codeUnitAt(0))) return null;
  if (name.isEmpty && i != end) return null;

  // Attributes: quotes and {} must be balanced before the final `>`.
  var depth = 0;
  String? quote;
  for (; i < end; i++) {
    final char = line[i];
    if (quote != null) {
      if (char == quote) quote = null;
    } else if (char == '"' || char == "'" || char == '`') {
      quote = char;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
    } else if (depth == 0 && (char == '<' || char == '>')) {
      return null;
    }
  }
  if (quote != null || depth != 0) return null;
  if (end > start + 1 && line[end - 1] == '/') return null;
  return name;
}

bool _isLetter(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122);

/// Turns plain snippet [text] with cursor [locations] (offsets into it, as
/// in `CustomCodeSnippet`) into LSP snippet syntax: `$1`, `$2`, ... in order.
String snippetWithStops(String text, Iterable<int> locations) {
  final sorted = locations.map((l) => l.clamp(0, text.length)).toSet().toList()
    ..sort();
  final out = StringBuffer();
  var last = 0;
  for (var i = 0; i < sorted.length; i++) {
    out
      ..write(escapeSnippetText(text.substring(last, sorted[i])))
      ..write('\$${i + 1}');
    last = sorted[i];
  }
  out.write(escapeSnippetText(text.substring(last)));
  return out.toString();
}
