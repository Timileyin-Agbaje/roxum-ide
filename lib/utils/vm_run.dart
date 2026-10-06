// Running a project on a remote VM over SSH: the per-project run target, SFTP sync
// of the project to ~/roxum/<project folder>, the commands run there, and the local
// tunnel used to preview a Vite dev server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  const VmSyncResult({required this.uploaded, required this.unchanged});
}

/// Mirrors a local project to `~/roxum/<project folder>` on a server, uploading only
/// files whose size or modified time changed since the last sync. Remote files are
/// never deleted, except by [clean].
class VmProjectSync {
  static const excludedDirs = {
    'node_modules', '.git', 'dist', 'build', '.vite', '.next', 'coverage',
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
      );
    } finally {
      await sftp.close();
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
echo \$\$ > "\$HOME/.roxum/run-$projectKey.pid"
trap 'rm -f "\$HOME/.roxum/run-$projectKey.pid"' EXIT
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

/// What pressing Play does on the VM for a file.
class VmRunPlan {
  /// The script body run from the project folder.
  final String body;

  /// True for a Vite dev server, which gets a preview tunnel.
  final bool isViteDevServer;

  const VmRunPlan({required this.body, this.isViteDevServer = false});

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
              ? '$install\nnpm run dev -- --host 127.0.0.1 --port $vitePort --strictPort'
              : '$install\nnpm run dev',
          isViteDevServer: isVite,
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

/// Forwards a free local port on the phone to the VM's Vite port over SSH.
class VmPreviewTunnel {
  final SSHClient client;
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
  Timer? _saveDebounce, _watchTimer, _statusClear;
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
        if (!quiet || result.uploaded > 0) {
          _setStatus(
            VmStatus(
              result.uploaded == 0
                  ? 'VM copy is up to date'
                  : 'Synced ${result.uploaded} file${result.uploaded == 1 ? '' : 's'} to ${server.name}',
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
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final client = server.client;
    if (client == null) return null;
    await stopDevServerTunnel();
    _server = server;
    final tunnel = VmPreviewTunnel(client);
    _tunnel = tunnel;

    final started = DateTime.now();
    while (!_disposed && identical(_tunnel, tunnel)) {
      if (await tunnel.isRemoteListening()) break;
      if (client.isClosed || DateTime.now().difference(started) > timeout) {
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

    // Close the tunnel once the dev server stops or SSH drops.
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!identical(_tunnel, tunnel)) return;
      if (client.isClosed || !await tunnel.isRemoteListening()) {
        await stopDevServerTunnel();
      }
    });
    return previewUrl;
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
    await stopDevServerTunnel();
    status.dispose();
  }
}
