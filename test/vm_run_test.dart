import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:roxum/utils/vm_run.dart';

void main() {
  group('VmProjectSync.isExcluded', () {
    test('skips build output, dependencies and logs at any depth', () {
      for (final excluded in [
        'node_modules/react/index.js',
        '.git/HEAD',
        'dist/app.js',
        'build/out.js',
        '.vite/deps/x.js',
        '.next/cache/a',
        'coverage/lcov.info',
        'packages/web/node_modules/x.js',
        'npm-debug.log',
        'logs/server.log',
        'node_modules',
      ]) {
        expect(VmProjectSync.isExcluded(excluded), isTrue, reason: excluded);
      }
    });

    test('keeps source files', () {
      for (final kept in [
        'src/main.tsx',
        'package.json',
        'index.html',
        'src/build.ts',
        'docs/logging.md',
        'distance.js',
      ]) {
        expect(VmProjectSync.isExcluded(kept), isFalse, reason: kept);
      }
    });
  });

  group('shQuote', () {
    test('quotes spaces and single quotes', () {
      expect(shQuote('a b'), "'a b'");
      expect(shQuote("it's"), "'it'\\''s'");
    });

    test('round-trips through a shell', () async {
      const value = "my project's \$HOME `x`";
      final result = await Process.run('sh', ['-c', 'printf %s ${shQuote(value)}']);
      expect(result.stdout, value);
    });
  });

  group('VmRunPlan.forFile', () {
    late Directory project;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('roxum plan ');
    });

    tearDown(() => project.delete(recursive: true));

    String file(String name) => path.join(project.path, name);

    test('runs TypeScript with tsx and JavaScript with node', () async {
      expect((await VmRunPlan.forFile(project.path, file('src/app.ts')))!.body,
          "npx --yes tsx 'src/app.ts'");
      expect((await VmRunPlan.forFile(project.path, file('a.tsx')))!.body,
          "npx --yes tsx 'a.tsx'");
      for (final ext in ['js', 'mjs', 'cjs']) {
        expect((await VmRunPlan.forFile(project.path, file('my app.$ext')))!.body,
            "node 'my app.$ext'");
      }
    });

    test('keeps HTML, CSS and other files on the phone', () async {
      for (final name in ['index.html', 'style.css', 'README.md', 'main.py']) {
        expect(await VmRunPlan.forFile(project.path, file(name)), isNull, reason: name);
      }
    });

    test('runs the Vite dev script on 127.0.0.1:5173 after installing when needed', () async {
      await File(file('package.json'))
          .writeAsString('{"scripts": {"dev": "vite", "build": "vite build"}}');
      final plan = (await VmRunPlan.forFile(project.path, file('src/App.tsx')))!;
      expect(plan.isViteDevServer, isTrue);
      expect(plan.body, contains('npm install'));
      expect(plan.body, contains('sha1sum --status -c node_modules/.roxum-deps'));
      expect(plan.body,
          endsWith('npm run dev -- --host 127.0.0.1 --port 5173 --strictPort'));
    });

    test('runs other dev scripts without Vite flags or a preview', () async {
      await File(file('package.json'))
          .writeAsString('{"scripts": {"dev": "nodemon server.js"}}');
      final plan = (await VmRunPlan.forFile(project.path, file('server.js')))!;
      expect(plan.isViteDevServer, isFalse);
      expect(plan.body, endsWith('npm run dev'));
    });

    test('ignores package.json without a dev script', () async {
      await File(file('package.json')).writeAsString('{"scripts": {"start": "node a.js"}}');
      final plan = (await VmRunPlan.forFile(project.path, file('a.js')))!;
      expect(plan.body, "node 'a.js'");
    });
  });

  group('VM package types', () {
    test('keeps only archive paths inside node_modules', () {
      expect(safeTypesEntryPath('node_modules/react/index.d.ts'), path.join('node_modules', 'react', 'index.d.ts'));
      expect(safeTypesEntryPath('./node_modules/@types/react/package.json'), isNotNull);
      for (final bad in ['src/app.ts', '/etc/passwd', 'node_modules/../../x', 'node_modules', '../node_modules/a']) {
        expect(safeTypesEntryPath(bad), isNull, reason: bad);
      }
    });

    test('replaces copied types and writes the stamp last', () async {
      final project = await Directory.systemTemp.createTemp('roxum-types');
      addTearDown(() => project.delete(recursive: true));
      await File(path.join(project.path, 'node_modules', 'old', 'index.d.ts')).create(recursive: true);

      final tar = Archive()
        ..add(ArchiveFile.string('node_modules/react/package.json', '{"types": "index.d.ts"}'))
        ..add(ArchiveFile.string('node_modules/react/index.d.ts', 'export {};'))
        ..add(ArchiveFile.string('node_modules/../evil.txt', 'no'));
      final bytes = Uint8List.fromList(const GZipEncoder().encodeBytes(TarEncoder().encodeBytes(tar)));
      await extractTypesArchive(bytes, project.path, 'abc  package.json');

      String read(String relative) => File(path.join(project.path, relative)).readAsStringSync();
      expect(read('node_modules/react/index.d.ts'), 'export {};');
      expect(read('node_modules/${VmTypesSync.stampName}'), 'abc  package.json');
      expect(File(path.join(project.path, 'node_modules', 'old', 'index.d.ts')).existsSync(), isFalse);
      expect(File(path.join(project.path, 'evil.txt')).existsSync(), isFalse);
    });
  });
}
