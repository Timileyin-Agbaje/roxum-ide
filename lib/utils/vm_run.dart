// Running a project on a remote VM over SSH: the per-project run target, SFTP sync
// of the project to ~/roxum/<project folder>, the commands run there, and the local
// tunnel used to preview a Vite dev server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'functions.dart';

/// Quotes [value] for a POSIX shell.
String shQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// Where the Play button runs code: null for the phone, otherwise a Termux or SSH server id.
class RunTargetStore {
  static String _key(String rootDir) => 'runTarget:$rootDir';

  static Future<int?> load(String rootDir) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(rootDir));
  }

  static Future<void> save(String rootDir, int? targetId) async {
    final prefs = await SharedPreferences.getInstance();
    if (targetId == null) {
      await prefs.remove(_key(rootDir));
    } else {
      await prefs.setInt(_key(rootDir), targetId);
    }
  }

  static const _syncOnSaveKey = 'vmSyncOnSave';

  static Future<bool> loadSyncOnSave() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncOnSaveKey) ?? true;
  }

  static Future<void> saveSyncOnSave(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncOnSaveKey, value);
  }
}

/// Lets editors announce saved files so a running VM dev server receives them.
class VmSaveEvents {
  static final _controller = StreamController<String>.broadcast();

  static Stream<String> get stream => _controller.stream;

  static void notifySaved(String filePath) => _controller.add(filePath);
}

/// Connects [server] if it has no live connection.
Future<(bool, String)> ensureVmConnected(SSHInfo server) async {
  final client = server.client;
  if (server.isConnected && client != null && !client.isClosed) {
    return (true, 'Already connected');
  }
  server.disconnect();
  return server.connect();
}

class VmSyncResult {
  final int uploaded;
  final int unchanged;
  final int deleted;

  const VmSyncResult({required this.uploaded, required this.unchanged, this.deleted = 0});
}

/// Mirrors a local project to `~/roxum/<project folder>` on a server, uploading only
/// files whose size or modified time changed since the last sync. Files it uploaded
/// that are gone on the phone (deleted or renamed) are deleted on the server; other
/// remote files (node_modules, dist, files made on the VM) are never touched.
class VmProjectSync {
  static const excludedDirs = {
    'node_modules', '.git', 'dist', 'build', '.vite', '.next', 'coverage',
    typesStagingDir,
  };
  static const maxFiles = 5000;

  /// Where upload manifests are kept (one file per server).
  static String manifestDir = '$appDir/vm-sync';

  final String rootDir;
  final SSHInfo server;

  VmProjectSync({required this.rootDir, required this.server});

  String get projectName => path.basename(rootDir);

  /// The project folder on the VM, relative to the login user's home.
  String get remoteRelativeDir => 'roxum/$projectName';

  /// The project folder for use in a shell command.
  String get remoteShellDir => '"\$HOME"/roxum/${shQuote(projectName)}';

  /// A file-name-safe key for this project, used for run scripts and pid files.
  String get projectKey => projectName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static bool isExcluded(String relativePath) {
    final parts = path.split(relativePath);
    if (parts.take(parts.length - 1).any(excludedDirs.contains)) return true;
    if (excludedDirs.contains(parts.last)) return true;
    return parts.last.endsWith('.log');
  }

  File get _manifestFile => File('$manifestDir/${server.id}.json');

  Future<Map<String, dynamic>> _loadAllManifests() async {
    try {
      if (await _manifestFile.exists()) {
        return jsonDecode(await _manifestFile.readAsString()) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Failed to read VM sync manifest: $e');
    }
    return {};
  }

  Future<Map<String, List<int>>> _loadManifest() async {
    final all = await _loadAllManifests();
    final entry = all[rootDir];
    if (entry is! Map) return {};
    return {
      for (final e in entry.entries)
        if (e.value is List && (e.value as List).length == 2)
          e.key.toString(): (e.value as List).cast<int>(),
    };
  }

  Future<void> _saveManifest(Map<String, List<int>>? manifest) async {
    final all = await _loadAllManifests();
    if (manifest == null) {
      all.remove(rootDir);
    } else {
      all[rootDir] = manifest;
    }
    await _manifestFile.parent.create(recursive: true);
    await _manifestFile.writeAsString(jsonEncode(all), flush: true);
  }

  /// Lists syncable files as relative path -> [size, modified time in ms].
  Future<Map<String, List<int>>> _scanLocal() async {
    final files = <String, List<int>>{};
    final pending = <Directory>[Directory(rootDir)];
    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      await for (final entity in dir.list(followLinks: false)) {
        final relative = path.relative(entity.path, from: rootDir);
        if (isExcluded(relative)) continue;
        if (entity is Directory) {
          pending.add(entity);
        } else if (entity is File) {
          final stat = await entity.stat();
          files[relative] = [stat.size, stat.modified.millisecondsSinceEpoch];
          if (files.length > maxFiles) {
            throw Exception(
              'This folder has more than $maxFiles files to sync. Open a smaller project folder.',
            );
          }
        }
      }
    }
    return files;
  }

  Future<void> _mkdirs(SftpClient sftp, String dir, Set<String> known) async {
    if (dir.isEmpty || dir == '.' || known.contains(dir)) return;
    final parent = path.posix.dirname(dir);
    if (parent != dir) await _mkdirs(sftp, parent, known);
    try {
      await sftp.mkdir(dir);
    } on SftpStatusError catch (_) {
      // Already exists (servers report this as a generic failure).
    }
    known.add(dir);
  }

  /// Uploads changed files, plus the absolute paths in [force] (just-saved files, in case
  /// a quick edit kept the same size and timestamp). [onProgress] receives (done, total)
  /// for files that need uploading.
  Future<VmSyncResult> sync({
    Set<String> force = const {},
    void Function(int done, int total)? onProgress,
  }) async {
    final client = server.client;
    if (client == null || client.isClosed) {
      throw Exception('Not connected to ${server.name}');
    }

    final local = await _scanLocal();
    var manifest = await _loadManifest();
    final sftp = await client.sftp();
    try {
      final home = await sftp.absolute('.');
      final remoteRoot = path.posix.join(home, remoteRelativeDir);

      // If the VM copy was removed outside the app, upload everything again.
      try {
        await sftp.stat(remoteRoot);
      } on SftpStatusError catch (_) {
        manifest = {};
      }

      // Only files this app uploaded (listed in the manifest) are ever deleted.
      final removed = manifest.keys.where((key) => !local.containsKey(key)).toList();
      for (final relative in removed) {
        final remotePath = path.posix.join(remoteRoot, path.split(relative).join('/'));
        try {
          await sftp.remove(remotePath);
        } on SftpStatusError catch (_) {
          // Already gone.
        }
        await _removeEmptyParents(sftp, path.posix.dirname(remotePath), remoteRoot);
      }

      final forced = force.map((file) => path.relative(file, from: rootDir)).toSet();
      final changed = local.entries.where((entry) {
        final previous = manifest[entry.key];
        return forced.contains(entry.key) ||
            previous == null ||
            previous[0] != entry.value[0] ||
            previous[1] != entry.value[1];
      }).toList();

      // The home folder and everything above it already exist.
      final knownDirs = <String>{home};
      for (var dir = home; path.posix.dirname(dir) != dir; dir = path.posix.dirname(dir)) {
        knownDirs.add(path.posix.dirname(dir));
      }
      await _mkdirs(sftp, remoteRoot, knownDirs);

      var done = 0;
      onProgress?.call(done, changed.length);
      try {
        for (final entry in changed) {
          final remotePath = path.posix.join(
            remoteRoot,
            path.split(entry.key).join('/'),
          );
          await _mkdirs(sftp, path.posix.dirname(remotePath), knownDirs);
          final bytes = await File(path.join(rootDir, entry.key)).readAsBytes();
          final file = await sftp.open(
            remotePath,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.truncate |
                SftpFileOpenMode.write,
          );
          try {
            await file.writeBytes(bytes);
          } finally {
            await file.close();
          }
          manifest[entry.key] = entry.value;
          done++;
          onProgress?.call(done, changed.length);
        }
      } finally {
        manifest.removeWhere((key, _) => !local.containsKey(key));
        await _saveManifest(manifest);
      }

      return VmSyncResult(
        uploaded: changed.length,
        unchanged: local.length - changed.length,
        deleted: removed.length,
      );
    } finally {
      await sftp.close();
    }
  }

  /// Removes folders left empty by a deletion, up to (not including) [root].
  Future<void> _removeEmptyParents(SftpClient sftp, String dir, String root) async {
    while (dir != root && path.posix.isWithin(root, dir)) {
      try {
        await sftp.rmdir(dir);
      } on SftpStatusError catch (_) {
        return; // Not empty.
      }
      dir = path.posix.dirname(dir);
    }
  }

  /// Deletes the VM copy of the project and forgets what was uploaded.
  Future<void> clean() async {
    final client = server.client;
    if (client == null || client.isClosed) {
      throw Exception('Not connected to ${server.name}');
    }
    await client.run(
      '$stopCommand; rm -rf $remoteShellDir "\$HOME/.roxum/run-$projectKey.sh"',
    );
    await _saveManifest(null);
  }

  String get _pidFile => '"\$HOME"/.roxum/run-$projectKey.pid';

  /// The dev server's output on the VM (see [VmRunPlan.detached]).
  String get logFile => '"\$HOME"/.roxum/run-$projectKey.log';

  /// Shows a running dev server's recent output and follows it until it stops.
  String get followLogCommand =>
      'tail -n 100 --pid="\$(cat $_pidFile)" -f $logFile';

  /// Whether this project's run (for example its dev server) is still going.
  Future<bool> isRunActive() async {
    final client = server.client;
    if (client == null || client.isClosed) return false;
    final out = await client.run(
      'f=$_pidFile; [ -s "\$f" ] && kill -0 -- -"\$(cat "\$f")" 2>/dev/null && echo running',
      stderr: false,
    );
    return utf8.decode(out).contains('running');
  }

  /// Ends this project's run on the VM: the whole process group started by the run script.
  String get stopCommand =>
      'f=$_pidFile; if [ -f "\$f" ]; then pid=\$(cat "\$f"); '
      'kill -TERM -- -"\$pid" 2>/dev/null; sleep 2; kill -KILL -- -"\$pid" 2>/dev/null; '
      'rm -f "\$f"; fi; true';

  /// Writes a run script for [body] to ~/.roxum and returns the command that runs it
  /// from the project folder. The script records its process group so [stopCommand]
  /// can end everything it started.
  Future<String> prepareRunCommand(String body) async {
    final client = server.client;
    if (client == null || client.isClosed) {
      throw Exception('Not connected to ${server.name}');
    }
    final script = '''#!/usr/bin/env bash
# Written by Roxum IDE for ${projectName.replaceAll('\n', ' ')}
mkdir -p "\$HOME/.roxum"
pidfile="\$HOME/.roxum/run-$projectKey.pid"
log="\$HOME/.roxum/run-$projectKey.log"
echo \$\$ > "\$pidfile"
trap 'rm -f "\$pidfile"' EXIT
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed on this VM. Run the 'Prepare the VM' steps in the README."
  exit 127
fi
$body
''';
    final sftp = await client.sftp();
    try {
      final home = await sftp.absolute('.');
      try {
        await sftp.mkdir(path.posix.join(home, '.roxum'));
      } on SftpStatusError catch (_) {}
      final file = await sftp.open(
        path.posix.join(home, '.roxum', 'run-$projectKey.sh'),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(utf8.encode(script));
      } finally {
        await file.close();
      }
    } finally {
      await sftp.close();
    }
    return 'cd $remoteShellDir && bash "\$HOME/.roxum/run-$projectKey.sh"';
  }
}

/// Copies type definitions (every package.json and .d.ts file) from the VM's
/// node_modules into the phone project, so the TypeScript server on the phone
/// knows the packages `npm install` put on the VM.
class VmTypesSync {
  /// Marks a phone node_modules made by this class, holding the VM's
  /// `.roxum-deps` stamp it was copied from.
  static const stampName = '.roxum-types';

  final VmProjectSync project;

  VmTypesSync(this.project);

  String get _modulesDir => path.join(project.rootDir, 'node_modules');

  String get _archive => '"\$HOME"/.roxum/types-${project.projectKey}.tgz';

  /// Copies the types if the VM's installed dependencies changed since the
  /// last copy. Returns true when the phone's types were replaced.
  /// [onCopying] runs once a copy starts.
  Future<bool> update({void Function()? onCopying}) async {
    final client = project.server.client;
    if (client == null || client.isClosed) return false;

    final localStamp = File(path.join(_modulesDir, stampName));
    final staging = Directory(path.join(project.rootDir, typesStagingDir));
    if (await staging.exists()) await staging.delete(recursive: true);
    // node_modules without our stamp is a real install on the phone: keep it.
    if (await Directory(_modulesDir).exists() && !await localStamp.exists()) {
      return false;
    }
    // Only a stamp that still matches package.json and the lockfile counts;
    // otherwise an install is pending or running.
    final checkStamp = 'sha1sum --status -c node_modules/.roxum-deps 2>/dev/null';
    final remoteStamp = utf8.decode(await client.run(
      'cd ${project.remoteShellDir} && $checkStamp && cat node_modules/.roxum-deps',
      stderr: false,
    )).trim();
    if (remoteStamp.isEmpty) return false;
    if (await localStamp.exists() && (await localStamp.readAsString()).trim() == remoteStamp) {
      return false;
    }
    onCopying?.call();

    final packed = utf8.decode(await client.run(
      'mkdir -p "\$HOME/.roxum" && cd ${project.remoteShellDir} && $checkStamp && '
      'find node_modules -path node_modules/typescript -prune -o -type f '
      "\\( -name package.json -o -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \\) -print0 "
      '| tar -czf $_archive --null -T - && $checkStamp && '
      '[ "\$(cat node_modules/.roxum-deps)" = ${shQuote(remoteStamp)} ] && echo packed',
      stderr: false,
    ));
    if (!packed.contains('packed')) {
      throw Exception('Could not pack the types on ${project.server.name}');
    }

    final sftp = await client.sftp();
    final Uint8List bytes;
    try {
      final home = await sftp.absolute('.');
      final file = await sftp.open(path.posix.join(home, '.roxum', 'types-${project.projectKey}.tgz'));
      try {
        bytes = await file.readBytes();
      } finally {
        await file.close();
      }
    } finally {
      sftp.close();
    }
    await client.run('rm -f $_archive');

    final rootDir = project.rootDir;
    await Isolate.run(() => extractTypesArchive(bytes, rootDir, remoteStamp));
    return true;
  }
}

/// Replaces `<projectDir>/node_modules` with the files in the gzipped tar
/// [bytes] (paths under node_modules only). It extracts into a temporary
/// folder with the stamp and swaps it in at the end, so an interrupted copy
/// never leaves a stamp-less node_modules that looks like a real install.
Future<void> extractTypesArchive(Uint8List bytes, String projectDir, String stamp) async {
  final archive = TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(bytes));
  final staging = Directory(path.join(projectDir, typesStagingDir));
  if (await staging.exists()) await staging.delete(recursive: true);
  for (final entry in archive) {
    final relative = safeTypesEntryPath(entry.name);
    if (relative == null || !entry.isFile || entry.isSymbolicLink) continue;
    final file = File(path.join(staging.path, path.relative(relative, from: 'node_modules')));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(entry.content);
  }
  await staging.create(recursive: true);
  await File(path.join(staging.path, VmTypesSync.stampName)).writeAsString(stamp);
  final modules = Directory(path.join(projectDir, 'node_modules'));
  if (await modules.exists()) await modules.delete(recursive: true);
  await staging.rename(modules.path);
}

/// Where [extractTypesArchive] builds the new copy before swapping it in.
const typesStagingDir = '.roxum-types-tmp';

/// The local relative path for an archive entry, or null unless it stays
/// inside node_modules.
String? safeTypesEntryPath(String name) {
  final normalized = path.posix.normalize(name.replaceAll('\\', '/'));
  final parts = path.posix.split(normalized);
  if (path.posix.isAbsolute(normalized) || parts.contains('..')) return null;
  if (parts.length < 2 || parts.first != 'node_modules') return null;
  return path.joinAll(parts);
}

/// What pressing Play does on the VM for a file.
class VmRunPlan {
  /// The script body run from the project folder.
  final String body;

  /// True for a Vite dev server, which gets a preview tunnel on [vitePort].
  final bool isViteDevServer;

  /// True for any `dev` script; other dev servers are previewed on the port
  /// they print.
  final bool isDevServer;

  const VmRunPlan({required this.body, this.isViteDevServer = false, this.isDevServer = false});

  /// Runs [command] in its own session with output to the run's log, and
  /// follows the log in this terminal. A dropped SSH connection then doesn't
  /// stop the dev server; Ctrl+C and Stop still do (the pid file holds the
  /// server's process group). Uses the run script's \$pidfile and \$log.
  static String detached(String command) => '''
trap - EXIT
rm -f "\$pidfile"
: > "\$log"
setsid bash -c 'echo \$\$ > "\$1"; trap "" HUP; $command; rm -f "\$1"' _ "\$pidfile" > "\$log" 2>&1 < /dev/null &
for _ in \$(seq 50); do [ -s "\$pidfile" ] && break; sleep 0.1; done
trap 'kill -INT -- -"\$(cat "\$pidfile" 2>/dev/null)" 2>/dev/null' INT
tail -n +1 --pid="\$(cat "\$pidfile")" -f "\$log"''';

  static const vitePort = 5173;

  /// Returns null when the file should keep running on the phone (HTML, CSS, Markdown...).
  static Future<VmRunPlan?> forFile(String rootDir, String filePath) async {
    final packageJson = File(path.join(rootDir, 'package.json'));
    if (await packageJson.exists()) {
      String? devScript;
      try {
        final parsed = jsonDecode(await packageJson.readAsString());
        final scripts = parsed is Map ? parsed['scripts'] : null;
        if (scripts is Map && scripts['dev'] is String) {
          devScript = scripts['dev'] as String;
        }
      } catch (_) {}

      if (devScript != null) {
        const install =
            'if [ ! -d node_modules ] || ! sha1sum --status -c node_modules/.roxum-deps 2>/dev/null; then\n'
            '  npm install || exit \$?\n'
            '  sha1sum package.json \$(ls package-lock.json npm-shrinkwrap.json 2>/dev/null) > node_modules/.roxum-deps\n'
            'fi';
        final isVite = devScript.contains('vite') ||
            await File(path.join(rootDir, 'vite.config.ts')).exists() ||
            await File(path.join(rootDir, 'vite.config.js')).exists();
        return VmRunPlan(
          body: isVite
              ? '$install\n${detached('npm run dev -- --host 127.0.0.1 --port $vitePort --strictPort')}'
              : '$install\n${detached('npm run dev')}',
          isViteDevServer: isVite,
          isDevServer: true,
        );
      }
    }

    final relative = path.split(path.relative(filePath, from: rootDir)).join('/');
    switch (path.extension(filePath)) {
      case '.ts':
      case '.tsx':
        return VmRunPlan(body: 'npx --yes tsx ${shQuote(relative)}');
      case '.js':
      case '.mjs':
      case '.cjs':
        return VmRunPlan(body: 'node ${shQuote(relative)}');
      default:
        return null;
    }
  }
}

/// The port of the first local URL a dev server printed
/// (`http://localhost:3000`, `http://127.0.0.1:8080/`...), ignoring colors.
int? devServerPortIn(String output) {
  final plain = output.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');
  final match = RegExp(r'https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})').firstMatch(plain);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Forwards a free local port on the phone to the VM's Vite port over SSH.
class VmPreviewTunnel {
  /// Replaced after a reconnect; the local port (and preview URL) stays.
  SSHClient client;
  final int remotePort;
  ServerSocket? _server;
  final Set<Socket> _sockets = {};

  VmPreviewTunnel(this.client, {this.remotePort = VmRunPlan.vitePort});

  int? get localPort => _server?.port;

  bool get isOpen => _server != null;

  Future<int> open() async {
    if (_server != null) return _server!.port;
    ServerSocket? server;
    for (var port = remotePort; port < remotePort + 20 && server == null; port++) {
      try {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException catch (_) {}
    }
    server ??= await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_forward);
    return server.port;
  }

  Future<void> _forward(Socket socket) async {
    _sockets.add(socket);
    try {
      final channel = await client.forwardLocal('127.0.0.1', remotePort);
      channel.stream.cast<List<int>>().pipe(socket).catchError((_) {});
      socket.cast<List<int>>().pipe(channel.sink).catchError((_) {});
      await channel.done;
    } catch (_) {
      // The dev server is not listening; drop the connection.
    } finally {
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  /// True if the VM's dev server accepts connections.
  Future<bool> isRemoteListening() async {
    if (client.isClosed) return false;
    try {
      final channel = await client
          .forwardLocal('127.0.0.1', remotePort)
          .timeout(const Duration(seconds: 5));
      channel.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await server?.close();
  }
}

/// Status of the VM work for the editor's status line.
class VmStatus {
  final String message;

  /// 0..1 while syncing, null otherwise.
  final double? progress;
  final bool isError;

  const VmStatus(this.message, {this.progress, this.isError = false});
}

/// Per-editor coordinator: syncs before runs, keeps syncing on save while a VM dev
/// server runs, and owns the preview tunnel.
class VmSession {
  final String rootDir;
  final ValueNotifier<VmStatus?> status = ValueNotifier(null);

  SSHInfo? _server;
  VmPreviewTunnel? _tunnel;
  StreamSubscription<String>? _saveSubscription;
  Timer? _saveDebounce, _watchTimer, _statusClear, _typesTimer;
  int _typesWatch = 0;
  Future<void> _typesCopy = Future.value();
  Future<void> _syncChain = Future.value();
  final Set<String> _savedSinceSync = {};
  bool _disposed = false;

  VmSession(this.rootDir);

  /// The phone-side URL of the VM dev server, while the tunnel is open.
  String? get previewUrl {
    final port = _tunnel?.localPort;
    return port == null ? null : 'http://127.0.0.1:$port';
  }

  bool get isDevServerRunning => _tunnel != null;

  VmProjectSync syncFor(SSHInfo server) =>
      VmProjectSync(rootDir: rootDir, server: server);

  void _setStatus(VmStatus? value, {Duration? clearAfter}) {
    if (_disposed) return;
    _statusClear?.cancel();
    status.value = value;
    if (clearAfter != null) {
      _statusClear = Timer(clearAfter, () {
        if (!_disposed) status.value = null;
      });
    }
  }

  /// Uploads changed files, reporting progress in [status]. Syncs are serialized.
  Future<VmSyncResult> sync(SSHInfo server, {bool quiet = false, Set<String> force = const {}}) {
    final completer = Completer<VmSyncResult>();
    _syncChain = _syncChain.catchError((_) {}).then((_) async {
      try {
        if (!quiet) _setStatus(VmStatus('Syncing to ${server.name}…', progress: 0));
        final result = await syncFor(server).sync(
          force: force,
          onProgress: (done, total) {
            if (total == 0) return;
            if (quiet && done == 0) {
              _setStatus(VmStatus('Syncing to ${server.name}…', progress: 0));
            }
            _setStatus(VmStatus(
              'Syncing to ${server.name}: $done of $total files',
              progress: done / total,
            ));
          },
        );
        if (!quiet || result.uploaded > 0 || result.deleted > 0) {
          _setStatus(
            VmStatus(
              result.uploaded == 0 && result.deleted == 0
                  ? 'VM copy is up to date'
                  : 'Synced ${result.uploaded} file${result.uploaded == 1 ? '' : 's'}'
                      '${result.deleted > 0 ? ', deleted ${result.deleted}' : ''} to ${server.name}',
            ),
            clearAfter: const Duration(seconds: 3),
          );
        }
        completer.complete(result);
      } catch (e) {
        _setStatus(VmStatus('Sync failed: $e', isError: true),
            clearAfter: const Duration(seconds: 8));
        completer.completeError(e);
      }
    });
    return completer.future;
  }

  /// Opens the preview tunnel and waits up to [timeout] for the VM dev server.
  /// Returns the preview URL, or null if the server never came up.
  Future<String?> startDevServerTunnel(
    SSHInfo server, {
    bool syncOnSave = true,
    int remotePort = VmRunPlan.vitePort,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final client = server.client;
    if (client == null) return null;
    await stopDevServerTunnel();
    _server = server;
    final tunnel = VmPreviewTunnel(client, remotePort: remotePort);
    _tunnel = tunnel;

    final started = Stopwatch()..start();
    while (!_disposed && identical(_tunnel, tunnel)) {
      if (await tunnel.isRemoteListening()) break;
      if (client.isClosed || started.elapsed > timeout) {
        await stopDevServerTunnel();
        return null;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    if (_disposed || !identical(_tunnel, tunnel)) return null;

    await tunnel.open();
    if (syncOnSave) {
      _saveSubscription = VmSaveEvents.stream
          .where((file) => path.isWithin(rootDir, file))
          .listen((file) {
        _savedSinceSync.add(file);
        _saveDebounce?.cancel();
        _saveDebounce = Timer(const Duration(milliseconds: 300), () {
          final saved = Set<String>.of(_savedSinceSync);
          _savedSinceSync.clear();
          sync(server, quiet: true, force: saved)
              .catchError((_) => const VmSyncResult(uploaded: 0, unchanged: 0));
        });
      });
    }

    // Close the tunnel once the dev server stops; if SSH drops (network
    // change), reconnect and keep the same preview URL.
    var busy = false;
    var unanswered = 0;
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!identical(_tunnel, tunnel) || busy) return;
      busy = true;
      try {
        final client = tunnel.client;
        if (!client.isClosed) {
          if (await tunnel.isRemoteListening()) {
            unanswered = 0;
            return;
          }
          if (!identical(_tunnel, tunnel)) return;
          if (await _isAlive(client)) {
            // The connection answers but the dev server doesn't: it stopped.
            if (identical(_tunnel, tunnel)) await stopDevServerTunnel();
            return;
          }
          // The connection is shared with the VM terminals, so one slow
          // moment must not cut it. Several unanswered checks in a row (a
          // network change can leave it hanging) mean it is dead.
          if (++unanswered < 3) return;
          client.close();
        }
        unanswered = 0;
        if (!await _reconnect(server, tunnel) && identical(_tunnel, tunnel)) {
          await stopDevServerTunnel();
        }
      } finally {
        busy = false;
      }
    });
    return previewUrl;
  }

  /// SSH keepalive ping: needs no session channel (servers limit those).
  static Future<bool> _isAlive(SSHClient client) async {
    try {
      await client.ping().timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reconnects to [server] with backoff for up to about five minutes, then
  /// points [tunnel] at the new connection. The dev server on the VM keeps
  /// running meanwhile (it is detached from the SSH session).
  Future<bool> _reconnect(SSHInfo server, VmPreviewTunnel tunnel) async {
    for (final seconds in const [1, 2, 4, 8, 15, 30, 30, 30, 30, 30, 30, 30, 30, 30]) {
      if (_disposed || !identical(_tunnel, tunnel)) return false;
      _setStatus(VmStatus('Reconnecting to ${server.name}…'));
      final (connected, _) = await ensureVmConnected(server);
      final client = server.client;
      if (connected && client != null) {
        tunnel.client = client;
        if (!await tunnel.isRemoteListening()) {
          _setStatus(VmStatus('Reconnected; the dev server on ${server.name} has stopped'),
              clearAfter: const Duration(seconds: 5));
          return false;
        }
        _setStatus(VmStatus('Reconnected to ${server.name}'), clearAfter: const Duration(seconds: 3));
        return true;
      }
      await Future.delayed(Duration(seconds: seconds));
    }
    _setStatus(VmStatus('Lost the connection to ${server.name}', isError: true),
        clearAfter: const Duration(seconds: 8));
    return false;
  }

  /// Waits for a dev server (other than Vite) to print its local URL in the
  /// run's log on the VM and returns the port, or null after [timeout].
  Future<int?> waitForDevServerPort(
    SSHInfo server, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final log = syncFor(server).logFile;
    final started = Stopwatch()..start();
    while (!_disposed && started.elapsed < timeout) {
      final client = server.client;
      if (client == null || client.isClosed) return null;
      try {
        final output = utf8.decode(
          await client.run('head -c 65536 $log 2>/dev/null', stderr: false),
          allowMalformed: true,
        );
        final port = devServerPortIn(output);
        if (port != null) return port;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  /// Copies the VM's package types to the phone once `npm install` has run
  /// there, checking every 5 s for up to [timeout] (the install may still be
  /// running). [onUpdated] runs after a copy.
  void watchTypes(
    SSHInfo server, {
    required VoidCallback onUpdated,
    Duration timeout = const Duration(minutes: 10),
  }) {
    _typesTimer?.cancel();
    final watch = ++_typesWatch;
    final types = VmTypesSync(syncFor(server));
    final started = Stopwatch()..start();
    var busy = false;
    Future<void> check() async {
      if (busy || _disposed || watch != _typesWatch) return;
      busy = true;
      // One copy at a time, even across Play presses.
      final previous = _typesCopy;
      final done = Completer<void>();
      _typesCopy = done.future;
      try {
        await previous;
        if (watch != _typesWatch || _disposed) return;
        final copied = await types.update(
          onCopying: () => _setStatus(VmStatus('Copying package types from ${server.name}…')),
        );
        if (watch != _typesWatch) return;
        if (copied) {
          _typesTimer?.cancel();
          _setStatus(VmStatus('Package types copied from ${server.name}'),
              clearAfter: const Duration(seconds: 3));
          onUpdated();
        } else if (started.elapsed > timeout) {
          _typesTimer?.cancel();
        }
      } catch (e) {
        if (watch != _typesWatch) return;
        _typesTimer?.cancel();
        _setStatus(VmStatus('Could not copy package types: $e', isError: true),
            clearAfter: const Duration(seconds: 8));
      } finally {
        busy = false;
        done.complete();
      }
    }

    unawaited(check());
    _typesTimer = Timer.periodic(const Duration(seconds: 5), (_) => check());
  }

  Future<void> stopDevServerTunnel() async {
    _watchTimer?.cancel();
    _watchTimer = null;
    _saveDebounce?.cancel();
    await _saveSubscription?.cancel();
    _saveSubscription = null;
    final tunnel = _tunnel;
    _tunnel = null;
    await tunnel?.close();
  }

  SSHInfo? get server => _server;

  Future<void> dispose() async {
    _disposed = true;
    _statusClear?.cancel();
    _typesTimer?.cancel();
    await stopDevServerTunnel();
    status.dispose();
  }
}
