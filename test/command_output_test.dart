import 'package:flutter_test/flutter_test.dart';
import 'package:roxum/terminal/command_output.dart';

void main() {
  // Buffer: 0 banner, 2 `npm run build` (output 3..5), 6 `ls` (output 7),
  // 8 the new prompt with the cursor.
  const commands = [2, 6];

  test(
    'a long-press anywhere in a command or its output finds that output',
    () {
      for (final line in [2, 3, 5]) {
        expect(commandOutputRange(commands, line, 8), (
          start: 3,
          end: 5,
        ), reason: '$line');
      }
      expect(commandOutputRange(commands, 7, 8), (start: 7, end: 7));
    },
  );

  test('above the first command, or a command without output, gives null', () {
    expect(commandOutputRange(commands, 1, 8), isNull);
    expect(commandOutputRange([2, 3], 2, 8), isNull);
    expect(commandOutputRange([8], 8, 8), isNull);
  });

  test('last output skips commands that printed nothing', () {
    expect(lastCommandOutputRange([2, 6, 8], 9), (start: 7, end: 7));
    expect(lastCommandOutputRange([], 3), isNull);
  });

  test('joins wrapped lines and trims trailing blanks', () {
    expect(
      joinTerminalLines([
        (text: 'vite v5 building  ', isWrapped: false),
        (text: 'dist/index.html ', isWrapped: false),
        (text: '0.4 kB', isWrapped: true),
        (text: '', isWrapped: false),
        (text: '   ', isWrapped: false),
      ]),
      'vite v5 building\ndist/index.html 0.4 kB',
    );
  });
}
