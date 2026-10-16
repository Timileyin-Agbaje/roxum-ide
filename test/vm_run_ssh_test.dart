// Integration tests for running on a VM. They need a real SSH server with Node.js
// and are skipped unless these are set:
//   ROXUM_TEST_SSH=ssh://user@host:port    ROXUM_TEST_SSH_KEY=/path/to/private_key
// They create and delete ~/roxum/<temp project> on that server.

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:roxum/utils/functions.dart';
import 'package:roxum/utils/vm_run.dart';

final _url = Platform.environment['ROXUM_TEST_SSH'];
final _key = Platform.environment['ROXUM_TEST_SSH_KEY'];

Future<String> _run(SSHInfo server, String command) async =>
    utf8.decode(await server.client!.run(command)).trim();

Future<String> _httpGet(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    expect(response.statusCode, 200);
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

Future<void> _until(Future<bool> Function() condition, {Duration timeout = const Duration(seconds: 20)}) async {
  final started = DateTime.now();
  while (!await condition()) {
    if (DateTime.now().difference(started) > timeout) {
      fail('Timed out after $timeout');
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
}

/// Runs [command] the way the app does: typed into an interactive SSH shell.
Future<SSHSession> _runInShell(SSHInfo server, String command, StringBuffer output) async {
  final session = await server.client!.shell(pty: const SSHPtyConfig(width: 200, height: 50));
  session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(output.write);
  session.write(utf8.encode('$command\n'));
  return session;
}

void main() {
  final skip = _url == null || _key == null
      ? 'Set ROXUM_TEST_SSH and ROXUM_TEST_SSH_KEY to run'
      : null;

  late SSHPrivateKey server;
  late Directory project;
  late Directory manifests;
  late VmProjectSync sync;

  setUpAll(() async {
    if (skip != null) return;
    manifests = await Directory.systemTemp.createTemp('roxum-manifests');
    VmProjectSync.manifestDir = manifests.path;
    server = SSHPrivateKey(name: 'test vm', id: 4242, url: _url!, termuxKeyLoc: File(_key!));
    final (ok, message) = await ensureVmConnected(server);
    expect(ok, isTrue, reason: message);
  });

  setUp(() async {
    if (skip != null) return;
    final parent = await Directory.systemTemp.createTemp('roxum-it');
    project = await Directory(path.join(parent.path, "it project ${DateTime.now().millisecondsSinceEpoch}")).create();
    sync = VmProjectSync(rootDir: project.path, server: server);
  });

  tearDown(() async {
    if (skip != null) return;
    await sync.clean();
    expect(await _run(server, 'ls "\$HOME/.roxum/run-${sync.projectKey}.sh" 2>/dev/null || true'), isEmpty);
    await project.parent.delete(recursive: true);
  });

  tearDownAll(() async {
    if (skip != null) return;
    server.disconnect();
    await manifests.delete(recursive: true);
  });

  Future<void> write(String relative, String content) async {
    final file = File(path.join(project.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  String remote(String relative) => '${sync.remoteShellDir}/${shQuote(relative)}';

  test('uploads only changed files and skips excluded folders', () async {
    await write('package.json', '{}');
    await write('src/index.ts', 'console.log(1)');
    await write('nested/deep/file.txt', 'deep');
    await write("it's here.js", 'x');
    await write('node_modules/dep/index.js', 'dep');
    await write('.git/HEAD', 'ref');
    await write('dist/out.js', 'out');
    await write('debug.log', 'log');

    var result = await sync.sync();
    expect(result.uploaded, 4);
    expect(await _run(server, 'cat ${remote('nested/deep/file.txt')}'), 'deep');
    expect(await _run(server, 'cat ${remote("it's here.js")}'), 'x');
    final listing = (await _run(server, 'cd ${sync.remoteShellDir} && ls -A')).split('\n');
    expect(listing, unorderedEquals(['package.json', 'src', 'nested', "it's here.js"]));

    result = await sync.sync();
    expect(result.uploaded, 0);
    expect(result.unchanged, 4);

    await Future.delayed(const Duration(milliseconds: 1100));
    await write('src/index.ts', 'console.log(2)');
    result = await sync.sync();
    expect(result.uploaded, 1);
    expect(await _run(server, 'cat ${remote('src/index.ts')}'), 'console.log(2)');

    // A VM copy removed outside the app is uploaded again in full.
    await _run(server, 'rm -rf ${sync.remoteShellDir}');
    result = await sync.sync();
    expect(result.uploaded, 4);
  }, skip: skip);

  test('force-uploads just-saved files even if size and timestamp match', () async {
    await write('same.js', 'aaa');
    await sync.sync();
    final file = File(path.join(project.path, 'same.js'));
    final modified = await file.lastModified();
    await file.writeAsString('bbb');
    await file.setLastModified(modified);

    expect((await sync.sync()).uploaded, 0);
    expect(await _run(server, 'cat ${remote('same.js')}'), 'aaa');
    expect((await sync.sync(force: {file.path})).uploaded, 1);
    expect(await _run(server, 'cat ${remote('same.js')}'), 'bbb');
  }, skip: skip);

  test('never deletes remote files', () async {
    await write('a.js', 'a');
    await write('b.js', 'b');
    await sync.sync();
    await File(path.join(project.path, 'b.js')).delete();
    await sync.sync();
    expect(await _run(server, 'cat ${remote('b.js')}'), 'b');
  }, skip: skip);

  test('copies package types from the VM once npm install has run', () async {
    await write('package.json', '{}');
    await sync.sync();
    final types = VmTypesSync(sync);
    final stamp = File(path.join(project.path, 'node_modules', VmTypesSync.stampName));
    expect(await types.update(), isFalse, reason: 'nothing installed yet');

    await _run(server, 'cd ${sync.remoteShellDir} && mkdir -p node_modules/react node_modules/typescript node_modules/.bin && '
        "echo '{}' > node_modules/react/package.json && echo 'export {};' > node_modules/react/index.d.ts && "
        "echo 'x' > node_modules/react/index.js && echo '{}' > node_modules/typescript/package.json && "
        "echo 'v1' > node_modules/.roxum-deps");
    expect(await types.update(), isTrue);
    expect(File(path.join(project.path, 'node_modules', 'react', 'index.d.ts')).readAsStringSync().trim(), 'export {};');
    expect(File(path.join(project.path, 'node_modules', 'react', 'index.js')).existsSync(), isFalse);
    expect(Directory(path.join(project.path, 'node_modules', 'typescript')).existsSync(), isFalse);
    expect(stamp.readAsStringSync(), 'v1');
    expect(await _run(server, 'ls "\$HOME"/.roxum/types-* 2>/dev/null || true'), isEmpty);

    expect(await types.update(), isFalse, reason: 'unchanged');
    await _run(server, "cd ${sync.remoteShellDir} && echo 'v2' > node_modules/.roxum-deps");
    expect(await types.update(), isTrue);
    expect(stamp.readAsStringSync(), 'v2');

    // A real install on the phone (no stamp) is left alone.
    await stamp.delete();
    await _run(server, "cd ${sync.remoteShellDir} && echo 'v3' > node_modules/.roxum-deps");
    expect(await types.update(), isFalse);
  }, skip: skip);

  test('runs JavaScript and TypeScript files on the VM', () async {
    await write('hello.js', 'console.log("hello from " + require("os").hostname())');
    await write('src/typed.ts', 'const n: number = 6 * 7; console.log(`answer \${n}`)');
    await sync.sync();

    final js = await VmRunPlan.forFile(project.path, path.join(project.path, 'hello.js'));
    final jsCommand = await sync.prepareRunCommand(js!.body);
    final hostname = await _run(server, 'hostname');
    expect(await _run(server, jsCommand), 'hello from $hostname');

    final ts = await VmRunPlan.forFile(project.path, path.join(project.path, 'src/typed.ts'));
    final tsCommand = await sync.prepareRunCommand(ts!.body);
    expect(await _run(server, tsCommand), endsWith('answer 42'));
  }, timeout: const Timeout(Duration(minutes: 3)), skip: skip);

  test('Ctrl+C in the shell ends the run and the shell stays usable', () async {
    await write('forever.js', 'console.log("started"); setInterval(() => {}, 1000)');
    await sync.sync();
    final plan = await VmRunPlan.forFile(project.path, path.join(project.path, 'forever.js'));
    final command = await sync.prepareRunCommand(plan!.body);

    final output = StringBuffer();
    final session = await _runInShell(server, command, output);
    await _until(() async => output.toString().contains('started'));
    final pidFile = '"\$HOME"/.roxum/run-${sync.projectKey}.pid';
    final group = await _run(server, 'cat $pidFile');
    expect(await _run(server, 'pgrep -g $group | wc -l'), isNot('0'));

    session.write(utf8.encode('\x03'));
    await _until(() async => await _run(server, 'test -f $pidFile && echo yes || echo no') == 'no');
    await _until(() async => await _run(server, 'pgrep -g $group | wc -l') == '0');

    session.write(utf8.encode('echo shell-alive-\$((40+2))\n'));
    await _until(() async => output.toString().contains('shell-alive-42'));
    session.close();
  }, skip: skip);

  test('stop command ends a run that ignores Ctrl+C, children included', () async {
    await write('stubborn.js', '''
process.on("SIGINT", () => console.log("ignoring SIGINT"));
require("child_process").spawn("sleep", ["300"], { stdio: "ignore" });
console.log("started");
setInterval(() => {}, 1000);
''');
    await sync.sync();
    final plan = await VmRunPlan.forFile(project.path, path.join(project.path, 'stubborn.js'));
    final command = await sync.prepareRunCommand(plan!.body);

    final output = StringBuffer();
    final session = await _runInShell(server, command, output);
    await _until(() async => output.toString().contains('started'));
    final group = await _run(server, 'cat "\$HOME"/.roxum/run-${sync.projectKey}.pid');
    // node, its sleep child and the run script share the group.
    expect(int.parse(await _run(server, 'pgrep -g $group | wc -l')), greaterThanOrEqualTo(3));

    session.write(utf8.encode('\x03'));
    await _until(() async => output.toString().contains('ignoring SIGINT'));
    expect(await _run(server, 'pgrep -g $group | wc -l'), isNot('0'));

    await _run(server, sync.stopCommand);
    expect(await _run(server, 'pgrep -g $group | wc -l'), '0');
    session.close();
  }, skip: skip);

  test('Vite dev server: install once, preview through the tunnel, sync on save', () async {
    await write('package.json', jsonEncode({
      'name': 'roxum-it',
      'private': true,
      'scripts': {'dev': 'vite'},
      'devDependencies': {'vite': '^6.0.0'},
    }));
    await write('index.html', '<!doctype html><html><body><h1>first version</h1></body></html>');

    final session = VmSession(project.path);
    addTearDown(session.dispose);
    await session.sync(server);
    final plan = (await VmRunPlan.forFile(project.path, path.join(project.path, 'index.html')))!;
    expect(plan.isViteDevServer, isTrue);
    final command = await sync.prepareRunCommand(plan.body);

    final output = StringBuffer();
    final shell = await _runInShell(server, command, output);
    final url = await session.startDevServerTunnel(server, timeout: const Duration(minutes: 4));
    expect(url, isNotNull, reason: output.toString());
    expect(output.toString(), contains('added'));
    expect(await _httpGet(url!), contains('first version'));

    // Saving a file syncs it while the dev server runs.
    await write('index.html', '<!doctype html><html><body><h1>second version</h1></body></html>');
    VmSaveEvents.notifySaved(path.join(project.path, 'index.html'));
    await _until(() async => (await _httpGet(url)).contains('second version'));

    // Dependencies are installed once.
    expect(
      await _run(server, 'cd ${sync.remoteShellDir} && sha1sum --status -c node_modules/.roxum-deps && echo current'),
      'current',
    );

    // Stopping the dev server closes the tunnel.
    shell.write(utf8.encode('\x03'));
    await _until(() async => !session.isDevServerRunning, timeout: const Duration(seconds: 30));
    shell.close();
  }, timeout: const Timeout(Duration(minutes: 6)), skip: skip);
}
