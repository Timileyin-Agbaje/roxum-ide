// Finding one command's output in a terminal buffer, for "Copy output".

/// The buffer lines holding the output of the command entered on a line in
/// [commandLines] (lines where Enter was sent), for a long-press on [line].
///
/// The output starts below the command line and ends before the next command
/// line, or for the last command before [cursorLine] (the new prompt). Returns
/// null when [line] is above every command or the command printed nothing.
({int start, int end})? commandOutputRange(
  List<int> commandLines,
  int line,
  int cursorLine,
) {
  final sorted = [...commandLines]..sort();
  int? command, next;
  for (final candidate in sorted) {
    if (candidate <= line) {
      command = candidate;
    } else {
      next = candidate;
      break;
    }
  }
  if (command == null) return null;
  final end = next != null
      ? next - 1
      : (cursorLine > command ? cursorLine - 1 : cursorLine);
  if (end <= command) return null;
  return (start: command + 1, end: end);
}

/// The output of the most recent command that printed something.
({int start, int end})? lastCommandOutputRange(
  List<int> commandLines,
  int cursorLine,
) {
  final sorted = [...commandLines]..sort();
  for (final command in sorted.reversed) {
    final range = commandOutputRange(sorted, command, cursorLine);
    if (range != null) return range;
  }
  return null;
}

/// Joins terminal lines into text: soft-wrapped lines continue the previous
/// one, trailing spaces and trailing blank lines are dropped.
String joinTerminalLines(Iterable<({String text, bool isWrapped})> lines) {
  final out = <String>[];
  for (final line in lines) {
    if (line.isWrapped && out.isNotEmpty) {
      out[out.length - 1] += line.text;
    } else {
      out.add(line.text);
    }
  }
  final trimmed = out.map((l) => l.trimRight()).toList();
  while (trimmed.isNotEmpty && trimmed.last.isEmpty) {
    trimmed.removeLast();
  }
  return trimmed.join('\n');
}
