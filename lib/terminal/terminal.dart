import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:roxum/l10n/app_localizations.dart';
import 'package:flutter_svg/svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bloc/ui_bloc/ui_bloc.dart';
import 'command_output.dart';
import '../utils/constants.dart';
import '../utils/functions.dart';
import '../utils/themes.dart';
import '../utils/vm_run.dart';

class SetupTerminal extends StatefulWidget {
  final String projectDir;
  final List<String> args;
  final bool useScaffold, showKeyboardMenu, readOnly;
  final bool isRun;
  final int? sshId, termuxId;
  final String? commandToExecuteInSSH;
  /// Run on the SSH server a few seconds after Stop sends Ctrl+C, to end what Ctrl+C missed.
  final String? remoteStopCommand;

  /// Identifies a project's run tab on a server, so Play reuses it.
  final String? runKey;

  /// Send [commandToExecuteInSSH] only if a new run tab had to be opened (for
  /// example following the log of a dev server that is already running).
  final bool runCommandOnlyInNewSession;

  const SetupTerminal({
    super.key,
    required this.projectDir,
    this.args = const [],
    this.useScaffold = true,
    this.showKeyboardMenu = true,
    this.readOnly = false,
    this.isRun = false,
    this.sshId,
    this.termuxId,
    this.commandToExecuteInSSH,
    this.remoteStopCommand,
    this.runKey,
    this.runCommandOnlyInNewSession = false,
  });

  @override
  State<SetupTerminal> createState() => _SetupTerminalState();
}

class EmbeddedTerminal extends StatelessWidget {
  final String projectDir;
  final List<String> args;
  final bool showKeyboardMenu;
  final bool readOnly;

  const EmbeddedTerminal({
    super.key,
    required this.projectDir,
    this.args = const [],
    this.showKeyboardMenu = true,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return SetupTerminal(
      projectDir: projectDir,
      args: args,
      useScaffold: false,
      showKeyboardMenu: showKeyboardMenu,
      readOnly: readOnly,
    );
  }
}

@immutable
class TerminalSessionMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final bool isRunning;

  const TerminalSessionMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.isRunning,
  });

  TerminalSessionMeta copyWith({String? title, bool? isRunning}) {
    return TerminalSessionMeta(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      isRunning: isRunning ?? this.isRunning,
    );
  }
}

@immutable
abstract class TerminalSessionEvent {}

class CreateTerminalSession extends TerminalSessionEvent {
  final String id;
  final String title;
  final bool makeActive;
  final bool isRunning;

  CreateTerminalSession({
    required this.id,
    required this.title,
    required this.makeActive,
    required this.isRunning,
  });
}

class SetActiveTerminalSession extends TerminalSessionEvent {
  final String id;
  SetActiveTerminalSession(this.id);
}

class DeleteTerminalSession extends TerminalSessionEvent {
  final String id;
  DeleteTerminalSession(this.id);
}

class UpdateTerminalSessionStatus extends TerminalSessionEvent {
  final String id;
  final bool isRunning;

  UpdateTerminalSessionStatus({required this.id, required this.isRunning});
}

class UpdateTerminalFontSize extends TerminalSessionEvent {
  final double fontSize;

  UpdateTerminalFontSize({required this.fontSize});
}

class TerminalSessionState {
  final List<TerminalSessionMeta> sessions;
  final String? activeSessionId;
  double fontSize;

  TerminalSessionState({
    required this.sessions,
    required this.activeSessionId,
    this.fontSize = 13.0
  });

  TerminalSessionState copyWith({
    List<TerminalSessionMeta>? sessions,
    String? activeSessionId,
    double? fontSize,
    bool clearActive = false,
  }) {
    return TerminalSessionState(
      sessions: sessions ?? this.sessions,
      activeSessionId: clearActive
        ? null
        : activeSessionId ?? this.activeSessionId,
      fontSize: fontSize ?? this.fontSize
    );
  }
}

class TerminalSessionBloc extends Bloc<TerminalSessionEvent, TerminalSessionState> {
  TerminalSessionBloc({double initialFontSize = 13}) : super(TerminalSessionState(sessions: [], activeSessionId: null, fontSize: initialFontSize)) {
    on<CreateTerminalSession>((event, emit) {
      final newSession = TerminalSessionMeta(
        id: event.id,
        title: event.title,
        createdAt: DateTime.now(),
        isRunning: event.isRunning,
      );
      final sessions = [newSession, ...state.sessions];
      emit(
        state.copyWith(
          sessions: sessions,
          activeSessionId: event.makeActive ? event.id : state.activeSessionId,
        ),
      );
    });

    on<SetActiveTerminalSession>((event, emit) {
      emit(state.copyWith(activeSessionId: event.id));
    });

    on<DeleteTerminalSession>((event, emit) {
      final sessions = state.sessions.where((session) => session.id != event.id).toList();
      if (sessions.isEmpty) {
        emit(state.copyWith(sessions: sessions, clearActive: true));
        return;
      }
      final activeId = state.activeSessionId == event.id ? sessions.first.id : state.activeSessionId;
      emit(state.copyWith(sessions: sessions, activeSessionId: activeId));
    });

    on<UpdateTerminalSessionStatus>((event, emit) {
      final sessions = state.sessions.map((session) {
        if (session.id == event.id) {
          return session.copyWith(isRunning: event.isRunning);
        }
        return session;
      }).toList();
      emit(state.copyWith(sessions: sessions));
    });

    on<UpdateTerminalFontSize>((event, emit) {
      emit(state.copyWith(fontSize: event.fontSize));
    });
  }
}

class TerminalRuntimeRegistry {
  TerminalRuntimeRegistry._();
  static final TerminalRuntimeRegistry instance = TerminalRuntimeRegistry._();

  final Map<String, TerminalRuntime> _runtimes = {};

  Map<String, TerminalRuntime> get runtimes => _runtimes;

  TerminalRuntime? get(String id) => _runtimes[id];
  bool has(String id) => _runtimes.containsKey(id);
  void put(String id, TerminalRuntime runtime) => _runtimes[id] = runtime;

  Future<void> remove(String id) async {
    final r = _runtimes.remove(id);
    await r?.dispose();
  }
}

class TerminalRuntime {
  final String sessionId;
  final String title;
  final Terminal terminal;
  final TerminalController controller;

  Pty? pty;
  SSHSession? sshSession;

  /// The SSH server (VM or Termux) this session runs on; null for the phone.
  SSHInfo? server;

  /// Set on a project's run tab (see [SetupTerminal.runKey]).
  String? runKey;

  /// Sent once when the SSH shell opens.
  String? runCommand;
  SSHClient? sshClient;
  String? sshStopCommand;
  String currentInput = '';
  VoidCallback? selectionListener;

  TerminalRuntime({
    required this.sessionId,
    required this.title,
    required this.terminal,
    required this.controller,
  });

  bool get isRunning {
    if (sshSession != null) return true;
    return pty != null;
  }

  /// Lines where Enter was sent, so a command's output can be found later.
  /// BufferLine keeps its index current as old lines scroll away.
  final List<BufferLine> _commandLines = [];

  /// Records Enter in what the user sends, before it reaches the shell.
  void noteInput(String data) {
    if (!data.contains('\r') && !data.contains('\n')) return;
    final buffer = terminal.buffer;
    _commandLines.add(buffer.lines[buffer.absoluteCursorY]);
    if (_commandLines.length > 500) _commandLines.removeAt(0);
  }

  /// Sends [data] to the phone shell or the SSH session.
  void write(String data) {
    noteInput(data);
    final bytes = utf8.encode(data);
    if (pty != null) {
      pty!.write(bytes);
    } else {
      sshSession?.write(bytes);
    }
  }

  List<int> get _commandLineIndexes => [
    for (final line in _commandLines)
      if (line.attached) line.index,
  ];

  String _text(int start, int end) {
    final lines = terminal.buffer.lines;
    return joinTerminalLines([
      for (var i = start; i <= end && i < lines.length; i++)
        (text: lines[i].getText(), isWrapped: lines[i].isWrapped),
    ]);
  }

  /// The output of the command whose block contains buffer [line].
  String? outputAt(int line) {
    final range = commandOutputRange(_commandLineIndexes, line, terminal.buffer.absoluteCursorY);
    return range == null ? null : _text(range.start, range.end);
  }

  String? get lastOutput {
    final range = lastCommandOutputRange(_commandLineIndexes, terminal.buffer.absoluteCursorY);
    return range == null ? null : _text(range.start, range.end);
  }

  /// The whole session, scrollback included.
  String get allText => _text(0, terminal.buffer.lines.length - 1);

  void stopProcess() {
    if(sshSession != null){
      // Interrupt the foreground program; the remote shell stays open.
      sshSession!.write(utf8.encode('\x03'));
      final client = sshClient;
      final stopCommand = sshStopCommand;
      if (client != null && stopCommand != null) {
        Future.delayed(const Duration(seconds: 3), () async {
          if (client.isClosed) return;
          try {
            await client.run(stopCommand);
          } catch (_) {}
        });
      }
    }
    if (pty != null) {
      try {
        pty!.kill(ProcessSignal.sigint);
      } catch (_) {}
      try {
        pty!.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        pty!.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    pty = null;
  }

  Future<void> dispose() async {
    stopProcess();
    sshSession?.close();
    if (selectionListener != null) {
      controller.removeListener(selectionListener!);
    }
    controller.dispose();
  }
}

class _SetupTerminalState extends State<SetupTerminal> {
  late final TerminalSessionBloc _sessionBloc;
  late final List<SSHInfo> sshServerList;
  late final SSHPrivateKey? termuxInfo;
  AnimationStatus _terminalSelectionStatus = .dismissed;
  String _sharedPath = '';

  OverlayEntry? _selectionToolbarOverlay;
  bool _hasSelection = false;
  Timer? _copyOnSelectTimer;
  String? _lastAutoCopied;

  void _copyText(String? text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (text == null || text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Nothing to copy'), duration: Duration(seconds: 1)));
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
  }

  final ValueNotifier<List<String>?> _suggestionsNotifier = ValueNotifier(null);
  final ScrollController _suggestionScrollController = ScrollController();
  int _selectedSuggestionIndex = 0;
  List<String> _pathBinaries = [];

  @override
  void initState() {
    super.initState();
    _sessionBloc = context.read<TerminalSessionBloc>();
    sshServerList = context.read<SSHServersCubit>().state.serverList.where((server) => server.isConnected).toList();
    termuxInfo = context.read<TermuxCubit>().state.termInfo;
    final hasSessions = _sessionBloc.state.sessions.isNotEmpty;
    if (hasSessions) {
      for (final meta in _sessionBloc.state.sessions) {
        if (TerminalRuntimeRegistry.instance.has(meta.id) && meta.isRunning) {
          _reattachSession(meta.id);
        } else {
          _restoreSession(meta);
        }
      }
    }
    if (widget.isRun) {
      _startRun();
    } else if (!hasSessions) {
      _bootstrapTerminalPage();
    }
    _loadPathBinaries();
  }

  /// Play reuses the project's run tab while its SSH shell is open, else
  /// opens a new one.
  Future<void> _startRun() async {
    final key = widget.runKey;
    final command = widget.commandToExecuteInSSH;
    final existing = key == null
        ? null
        : TerminalRuntimeRegistry.instance.runtimes.values
            .where((r) => r.runKey == key && r.sshSession != null)
            .firstOrNull;
    if (existing != null) {
      _sessionBloc.add(SetActiveTerminalSession(existing.sessionId));
      if (command != null && !widget.runCommandOnlyInNewSession) {
        existing.write('$command\n');
      }
      return;
    }
    await _bootstrapTerminalPage(title: 'Run', runKey: key, runCommand: command);
  }

  Future<void> _bootstrapTerminalPage({String? title, String? runKey, String? runCommand}) async {
    _sharedPath = await NativeChannel.getLibraryPath();
    final workDir = Directory(widget.projectDir);
    if (!workDir.existsSync()) {
      await workDir.create(recursive: true);
    }
    if (!mounted) return;
    await _createSession(
      args: widget.args,
      makeActive: true,
      title: title ?? 'Session 1',
      runKey: runKey,
      runCommand: runCommand,
      externalServer: ((){
        final sshId = widget.sshId;
        final termuxId = widget.termuxId;
        if (sshId != null) {
          return sshServerList.singleWhere((server) => server.id == sshId);
        } else if(termuxId != null) {
          return termuxInfo;
        }
      })()
    );
  }

  void _onSelectionChanged(String sessionId) {
    if (_sessionBloc.state.activeSessionId != sessionId) return;
    final runtime = TerminalRuntimeRegistry.instance.get(sessionId);
    if (runtime == null) return;

    final hasSelection = runtime.controller.selection != null;
    // Copy a selection once it stops changing.
    _copyOnSelectTimer?.cancel();
    if (hasSelection) {
      _copyOnSelectTimer = Timer(const Duration(milliseconds: 700), () {
        final selection = runtime.controller.selection;
        if (selection == null || !mounted) return;
        final text = runtime.terminal.buffer.getText(selection);
        if (text.trim().isEmpty || text == _lastAutoCopied) return;
        _lastAutoCopied = text;
        _copyText(text);
      });
    }
    if (hasSelection != _hasSelection) {
      // Rebuild so the terminal turns read-only (no keyboard) while selecting.
      setState(() => _hasSelection = hasSelection);
      if (hasSelection) {
        _showSelectionToolbar();
      } else {
        _hideSelectionToolbar();
      }
    }
  }

  TerminalRuntime? _activeRuntime() {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    final activeId = _sessionBloc.state.activeSessionId;
    if (activeId == null) return null;
    return sessionRuntimes[activeId];
  }

  String _nextSessionTitle() {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    final count = sessionRuntimes.length + 1;
    return AppLocalizations.of(context)!.sessionNumber(count);
  }

  Future<void> _createSession({
    List<String> args = const [],
    bool makeActive = true,
    String? title,
    bool showFeedback = false,
    SSHInfo? externalServer,
    String? runKey,
    String? runCommand,
  }) async {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final sessionTitle = title ?? _nextSessionTitle();
    final runtime = TerminalRuntime(
      sessionId: id,
      title: sessionTitle,
      terminal: Terminal(platform: TerminalTargetPlatform.android, maxLines: 5000),
      controller: TerminalController(selectionMode: SelectionMode.block),
    );

    runtime
      ..runKey = runKey
      ..runCommand = runCommand;
    runtime.selectionListener = () => _onSelectionChanged(id);
    runtime.controller.addListener(runtime.selectionListener!);
    sessionRuntimes[id] = runtime;

    _sessionBloc.add(
      CreateTerminalSession(
        id: id,
        title: sessionTitle,
        makeActive: makeActive,
        isRunning: false,
      ),
    );

    await _startPty(runtime, args: args, externalServer: externalServer);

    if (showFeedback && mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.newSessionCreated(sessionTitle)),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _restoreSession(TerminalSessionMeta meta) async {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    final workDir = Directory(widget.projectDir);
    if (!workDir.existsSync()) {
      await workDir.create(recursive: true);
    }
    if (!mounted) return;

    final runtime = TerminalRuntime(
      sessionId: meta.id,
      title: meta.title,
      terminal: Terminal(platform: TerminalTargetPlatform.android, maxLines: 5000),
      controller: TerminalController(selectionMode: SelectionMode.block),
    );
    runtime.selectionListener = () => _onSelectionChanged(meta.id);
    runtime.controller.addListener(runtime.selectionListener!);
    sessionRuntimes[meta.id] = runtime;

    await _startPty(runtime, args: widget.args);
  }

  void _reattachSession(String id) {
    final runtime = TerminalRuntimeRegistry.instance.get(id)!;

    if (runtime.selectionListener != null) {
      runtime.controller.removeListener(runtime.selectionListener!);
    }
    runtime.selectionListener = () => _onSelectionChanged(id);
    runtime.controller.addListener(runtime.selectionListener!);

    final process = runtime.pty;
    if (process != null) {
      runtime.terminal.onOutput = (data) {
        runtime.noteInput(data);
        if (widget.readOnly) return;
        process.write(const Utf8Encoder().convert(data));
        if (_sessionBloc.state.activeSessionId == id) {
          _handleInputForAutocomplete(runtime, data);
        }
      };
      runtime.terminal.onResize = (w, h, pw, ph) => process.resize(h, w);
    } else if (runtime.sshSession != null) {
      runtime.terminal.onOutput = (data) {
        runtime.noteInput(data);
        runtime.sshSession!.write(utf8.encode(data));
      };
      runtime.terminal.onResize = (w, h, pw, ph) {
        runtime.sshSession!.resizeTerminal(w, h, pw, ph);
      };
    }
  }

  Future<void> _restartSession(String sessionId) async {
    final runtime = TerminalRuntimeRegistry.instance.get(sessionId)!;
    runtime.stopProcess();
    runtime.currentInput = '';
    if (_sessionBloc.state.activeSessionId == sessionId) {
      _suggestionsNotifier.value = null;
    }
    // An SSH session restarts on the same server, reconnecting if needed.
    final server = runtime.server;
    if (server != null) {
      runtime.sshSession?.close();
      runtime.sshSession = null;
      final (connected, message) = await ensureVmConnected(server);
      if (!connected) {
        runtime.terminal.write('\r\nCould not reconnect to ${server.name}: $message\r\n');
        return;
      }
      await _startPty(runtime, externalServer: server);
      return;
    }
    await _startPty(runtime);
  }

  void _terminateSession(String sessionId) {
    final runtime = TerminalRuntimeRegistry.instance.get(sessionId)!;
    if (!runtime.isRunning) return;
    runtime.stopProcess();
    // An SSH shell outlives the interrupted program; its status changes when the shell ends.
    if (runtime.sshSession != null) return;
    _sessionBloc.add(
      UpdateTerminalSessionStatus(id: sessionId, isRunning: false),
    );
  }

  Future<void> _deleteSession(String sessionId) async {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    if (!sessionRuntimes.containsKey(sessionId)) return;

    final isLastSession = sessionRuntimes.length == 1;

    if (isLastSession) {
      final runtime = sessionRuntimes.remove(sessionId);
      await runtime?.dispose();
      _sessionBloc.add(DeleteTerminalSession(sessionId));
      _hideSelectionToolbar();
      _suggestionsNotifier.value = null;
      _hasSelection = false;

      if (mounted) {
        Navigator.of(context).pop();
        Navigator.of(context).pop();
      }
      return;
    }

    final runtime = sessionRuntimes.remove(sessionId);
    await runtime?.dispose();
    _sessionBloc.add(DeleteTerminalSession(sessionId));

    if (_sessionBloc.state.activeSessionId == sessionId) {
      _hideSelectionToolbar();
      _suggestionsNotifier.value = null;
      _hasSelection = false;
    }
  }

  Future<void> _loadPathBinaries() async {
    final pathDirs = [
      binDir,
      '$runtimesDir/node/bin',
      '/bin',
      '/usr/bin',
      '/sbin',
      '/usr/sbin',
    ];

    final binaries = <String>{};
    for (final dirPath in pathDirs) {
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              final name = entity.path.split('/').last;
              binaries.add(name);
            }
          }
        }
      } catch (_) {}
    }
    _pathBinaries = binaries.toList()..sort();
  }

  Future<void> _ensureBashRc() async {
    try {
      final bashrc = File('$homeDir/.bashrc');
      final aliases = [
        'alias ls="ls --color=auto"',
        'alias ll="ls -ll"',
        'alias la="ls -la"',
      ];
      if (!await bashrc.exists()) {
        await bashrc.create(recursive: true);
        await bashrc.writeAsString('${aliases.join('\n')}\n', flush: true);
        return;
      }

      final existing = await bashrc.readAsString();
      final missing = aliases.where((alias) => !existing.contains(alias)).toList();
      if (missing.isNotEmpty) {
        await bashrc.writeAsString('${existing.trimRight()}\n${missing.join('\n')}\n', flush: true);
      }
    } catch (_) {
    }
  }

  Future<void> _saveTerminalFontSize(double fontSize) async {
    final configState = context.read<ConfigBloc>().state;
    final currentConfig = Map<String, dynamic>.from(configState.codeForgeConfig);
    currentConfig['terminalFontSize'] = fontSize;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('codeForgeConfig', jsonEncode(currentConfig));
    if (!mounted) return;
    context.read<ConfigBloc>().add(ChangeConfigEvent(currentConfig));
  }

  void _onTerminalFontSizeChanged(double fontSize) {
    if (fontSize < 8) fontSize = 8;
    if (fontSize > 32) fontSize = 32;
    _sessionBloc.add(UpdateTerminalFontSize(fontSize: fontSize));
    _saveTerminalFontSize(fontSize);
  }

  Future<void> _startPty(
    TerminalRuntime runtime, {
    List<String> args = const [],
    SSHInfo? externalServer,
  }) async {
    final sessionRuntimes = TerminalRuntimeRegistry.instance.runtimes;
    if(externalServer != null && externalServer.client != null){
      runtime.server = externalServer;
      final terminal = runtime.terminal;
      final session = await externalServer.client!.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );

      runtime.sshSession = session;
      runtime.sshClient = externalServer.client;
      runtime.sshStopCommand = widget.remoteStopCommand;
      _sessionBloc.add(
        UpdateTerminalSessionStatus(id: runtime.sessionId, isRunning: true),
      );

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);
      terminal.onResize = (w, h, pw, ph) {
        session.resizeTerminal(w, h, pw, ph);
      };
      
      if(widget.termuxId != null) {
        session.write(utf8.encode("cd ${widget.projectDir}\n"));
      }
      
      final runCommand = runtime.runCommand;
      runtime.runCommand = null;
      if (runCommand != null) {
        runtime.write('$runCommand\n');
      }

      terminal.onOutput = (data) {
        runtime.noteInput(data);
        session.write(utf8.encode(data));
      };

      session.stdout
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

      session.stderr
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

      session.done.then((_) {
        if (identical(runtime.sshSession, session)) runtime.sshSession = null;
        if (!sessionRuntimes.containsKey(runtime.sessionId)) return;
        runtime.terminal.write('\r\n\n[Program finished with exit code ${session.exitCode}]');
        _sessionBloc.add(
          UpdateTerminalSessionStatus(id: runtime.sessionId, isRunning: false),
        );
      });

      return;
    }

    if (_sharedPath.isEmpty) {
      _sharedPath = await NativeChannel.getLibraryPath();
    }

    await _ensureBashRc();

    final enVars = <String, String>{
      'HOME': homeDir,
      'PS1': ' \x1b[32m\\w \x1b[0m\$ ',
      'PATH': '$binDir:$runtimesDir/node/bin:/bin:/usr/bin:/sbin:/usr/sbin',
      'PROMPT_DIRTRIM': '2',
      'ROXUM_SHARED_PATH': _sharedPath,
      'LD_LIBRARY_PATH': '$_sharedPath:$libDir:$runtimesDir/clang',
      'LD_PRELOAD': '$_sharedPath/libc++_shared.so',
      'PREFIX': appDir,
      'TMPDIR': tempDir,
      'JAVA_HOME': '$runtimesDir/java-21-openjdk',
      'GIT_EXEC_PATH': '$binDir/git-core',
      'GIT_SSL_CAINFO': '$certDir/cacert.pem',
      'CURL_CA_BUNDLE': '$certDir/cacert.pem',
      'SSL_CERT_FILE': '$certDir/cacert.pem',
      'ZIG_LIB_DIR': '$runtimesDir/zig/lib',
      'RUSTFLAGS': '--sysroot $runtimesDir/rust',
      'GOROOT': '$runtimesDir/go',
      'CC': 'clang'
    };

    final process = Pty.start(
      '$_sharedPath/libbash.so',
      workingDirectory: widget.projectDir,
      environment: enVars,
      rows: runtime.terminal.viewHeight,
      columns: runtime.terminal.viewWidth,
      arguments: args,
    );

    runtime.pty = process;
    _sessionBloc.add(
      UpdateTerminalSessionStatus(id: runtime.sessionId, isRunning: true),
    );

    process.output
      .cast<List<int>>()
      .transform(const Utf8Decoder())
      .listen(runtime.terminal.write);

    process.exitCode.then((code) {
      if (!sessionRuntimes.containsKey(runtime.sessionId)) return;
      runtime.pty = null;
      runtime.terminal.write('\r\n\n[Program finished with exit code $code]');
      _sessionBloc.add(
        UpdateTerminalSessionStatus(id: runtime.sessionId, isRunning: false),
      );
    });

    runtime.terminal.onOutput = (data) {
      runtime.noteInput(data);
      if (widget.readOnly) {
        return;
      }

      final activeSessionId = _sessionBloc.state.activeSessionId;
      process.write(const Utf8Encoder().convert(data));
      if (activeSessionId == runtime.sessionId) {
        _handleInputForAutocomplete(runtime, data);
      }
    };

    runtime.terminal.onResize = (w, h, pw, ph) {
      process.resize(h, w);
    };

    if (widget.readOnly) {
      _suggestionsNotifier.value = null;
      _hideSelectionToolbar();
      runtime.controller.clearSelection();
    }
  }

  void _handleInputForAutocomplete(TerminalRuntime runtime, String data) {
    if (data == '\r' || data == '\n') {
      _suggestionsNotifier.value = null;
      runtime.currentInput = '';
      return;
    }

    if (data == '\x7f' || data == '\b') {
      if (runtime.currentInput.isNotEmpty) {
        runtime.currentInput = runtime.currentInput.substring(
          0,
          runtime.currentInput.length - 1,
        );
      }
    } else if (data == '\t') {
      final suggestions = _suggestionsNotifier.value;
      if (suggestions != null && suggestions.isNotEmpty) {
        _acceptSuggestion(runtime, suggestions[_selectedSuggestionIndex]);
      }
      return;
    } else if (data == ' ' || data.contains('\x1b')) {
      _suggestionsNotifier.value = null;
      runtime.currentInput = '';
      return;
    } else if (data.length == 1 && data.codeUnitAt(0) >= 32) {
      runtime.currentInput += data;
    } else {
      return;
    }

    _updateSuggestions(runtime);
  }

  Future<void> _updateSuggestions(TerminalRuntime runtime) async {
    if (runtime.currentInput.isEmpty) {
      _suggestionsNotifier.value = null;
      return;
    }

    final query = runtime.currentInput.toLowerCase();
    List<String> matches = [];

    if (runtime.currentInput.startsWith('./') ||
        runtime.currentInput.startsWith('/') ||
        runtime.currentInput.startsWith('~/') ||
        runtime.currentInput.contains('/')) {
      matches = await _getPathSuggestions(runtime.currentInput);
    } else {
      matches = _pathBinaries
          .where((bin) => bin.toLowerCase().startsWith(query))
          .take(10)
          .toList();
    }

    if (matches.isEmpty) {
      _suggestionsNotifier.value = null;
    } else {
      _selectedSuggestionIndex = 0;
      _suggestionsNotifier.value = matches;
    }
  }

  Future<List<String>> _getPathSuggestions(String input) async {
    try {
      String searchPath;
      String prefix = '';

      if (input.startsWith('~/')) {
        searchPath = homeDir + input.substring(1);
        prefix = '~/';
      } else if (input.startsWith('./')) {
        searchPath = '${widget.projectDir}/${input.substring(2)}';
        prefix = './';
      } else if (input.startsWith('/')) {
        searchPath = input;
        prefix = '';
      } else {
        searchPath = '${widget.projectDir}/$input';
        prefix = '';
      }

      final lastSlash = searchPath.lastIndexOf('/');
      final dirPath = lastSlash >= 0
          ? searchPath.substring(0, lastSlash + 1)
          : searchPath;
      final partial = lastSlash >= 0
          ? searchPath.substring(lastSlash + 1).toLowerCase()
          : '';

      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];

      final suggestions = <String>[];
      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        if (partial.isEmpty || name.toLowerCase().startsWith(partial)) {
          final isDir = entity is Directory;
          final displayPath = prefix.isEmpty
              ? entity.path
              : prefix +
                    entity.path.substring(
                      input.startsWith('~/')
                          ? homeDir.length
                          : input.startsWith('./')
                          ? widget.projectDir.length + 1
                          : 0,
                    );
          suggestions.add(isDir ? '$displayPath/' : displayPath);
        }
      }

      suggestions.sort();
      return suggestions.take(10).toList();
    } catch (_) {
      return [];
    }
  }

  void _acceptSuggestion(TerminalRuntime runtime, String suggestion) {
    final process = runtime.pty;
    if (process == null) return;
    final toSend = suggestion.substring(runtime.currentInput.length);
    process.write(const Utf8Encoder().convert(toSend));
    runtime.currentInput = suggestion;
    _suggestionsNotifier.value = null;
  }

  void _showSelectionToolbar() {
    _hideSelectionToolbar();
    if (!mounted) return;

    final runtime = _activeRuntime();
    if (runtime == null) return;

    final overlay = Overlay.of(context);

    _selectionToolbarOverlay = OverlayEntry(
      builder: (context) {
        return Positioned(
          top: 60,
          left: 0,
          right: 0,
          child: Center(
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(24),
              color: const Color(0xff2d2d2d),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff454545)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _toolbarButton(
                      icon: Icons.copy,
                      label: AppLocalizations.of(context)!.copy,
                      onTap: () {
                        final selectedText =
                            runtime.controller.selection != null
                            ? runtime.terminal.buffer.getText(
                                runtime.controller.selection!,
                              )
                            : '';
                        if (selectedText.isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: selectedText));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('Copied to clipboard'),
                              duration: const Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          );
                        }
                        runtime.controller.clearSelection();
                      },
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: const Color(0xff454545),
                    ),
                    _toolbarButton(
                      icon: Icons.notes,
                      label: 'Copy output',
                      onTap: () {
                        final selection = runtime.controller.selection;
                        _copyText(
                          selection == null ? null : runtime.outputAt(selection.begin.y),
                        );
                        runtime.controller.clearSelection();
                      },
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: const Color(0xff454545),
                    ),
                    _toolbarButton(
                      icon: Icons.paste,
                      label: AppLocalizations.of(context)!.paste,
                      onTap: () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (data?.text != null) {
                          runtime.write(data!.text!);
                        }
                        runtime.controller.clearSelection();
                      },
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: const Color(0xff454545),
                    ),
                    _toolbarButton(
                      icon: Icons.search,
                      label: 'Search',
                      onTap: () {
                        final selectedText =
                            runtime.controller.selection != null
                            ? runtime.terminal.buffer.getText(
                                runtime.controller.selection!,
                              )
                            : '';
                        if (selectedText.isNotEmpty) {
                          runtime.write(
                            'grep -r "${selectedText.replaceAll('"', '\\"')}" .',
                          );
                        }
                        runtime.controller.clearSelection();
                      },
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: const Color(0xff454545),
                    ),
                    _toolbarButton(
                      icon: Icons.close,
                      label: '',
                      onTap: () {
                        runtime.controller.clearSelection();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(_selectionToolbarOverlay!);
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: label.isEmpty ? 8 : 12,
          vertical: 8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.9)),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _hideSelectionToolbar() {
    _selectionToolbarOverlay?.remove();
    _selectionToolbarOverlay = null;
  }

  void sendToPty(String sequence) {
    _activeRuntime()?.write(sequence);
  }

  void _setTerminalOutputWithAutocomplete({
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
    VoidCallback? resetCallback,
  }) {
    final runtime = _activeRuntime();
    // CTRL/ALT/SHIFT work for phone and SSH (VM) sessions alike.
    if (runtime == null || (runtime.pty == null && runtime.sshSession == null)) {
      return;
    }

    runtime.terminal.onOutput = (data) {
      runtime.noteInput(data);
      String sequence = '';

      if (ctrl) {
        if (data.length == 1) {
          int code = data.toUpperCase().codeUnitAt(0);
          if (code >= 65 && code <= 90) {
            sequence = String.fromCharCode(code - 64);
          }
        }
      } else if (alt) {
        sequence = '\x1b$data';
      } else if (shift) {
        sequence = data.toUpperCase();
      } else {
        sequence = data;
      }

      if (sequence.isNotEmpty) {
        final process = runtime.pty;
        if (process != null) {
          process.write(const Utf8Encoder().convert(sequence));
          _handleInputForAutocomplete(runtime, sequence);
        } else {
          runtime.sshSession?.write(utf8.encode(sequence));
        }
      }

      if ((ctrl || alt || shift) && resetCallback != null) {
        resetCallback();
        _setTerminalOutputWithAutocomplete();
      }
    };
  }

  @override
  void dispose() {
    _copyOnSelectTimer?.cancel();
    _hideSelectionToolbar();
    _suggestionsNotifier.dispose();
    _suggestionScrollController.dispose();
    super.dispose();
  }

  Widget _buildSuggestionBox() {
    if (widget.readOnly) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<List<String>?>(
      valueListenable: _suggestionsNotifier,
      builder: (context, suggestions, _) {
        if (suggestions == null || suggestions.isEmpty) {
          _selectedSuggestionIndex = 0;
          return const SizedBox.shrink();
        }

        final screenWidth = MediaQuery.of(context).size.width;
        const itemHeight = 40.0;
        final maxHeight = (suggestions.length * itemHeight).clamp(0.0, 300.0);

        return Positioned(
          left: 8,
          right: 8,
          bottom: 100,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: const Color(0xff252526),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: maxHeight,
                maxWidth: screenWidth - 16,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xff3c3c3c), width: 0.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: RawScrollbar(
                  thumbVisibility: true,
                  thumbColor: Colors.white.withValues(alpha: 0.3),
                  controller: _suggestionScrollController,
                  child: ListView.builder(
                    controller: _suggestionScrollController,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemExtent: itemHeight,
                    itemCount: suggestions.length,
                    itemBuilder: (context, index) {
                      final suggestion = suggestions[index];
                      final isSelected = index == _selectedSuggestionIndex;
                      final isDirectory = suggestion.endsWith('/');
                      final isPath = suggestion.contains('/');
                      final activeRuntime = _activeRuntime();

                      return InkWell(
                        onTap: activeRuntime == null
                            ? null
                            : () =>
                                  _acceptSuggestion(activeRuntime, suggestion),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          color: isSelected
                              ? const Color(0xff094771)
                              : Colors.transparent,
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: isDirectory
                                      ? Colors.amber.withValues(alpha: 0.15)
                                      : isPath
                                      ? Colors.blue.withValues(alpha: 0.15)
                                      : Colors.green.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Icon(
                                  isDirectory
                                      ? Icons.folder_rounded
                                      : isPath
                                      ? Icons.insert_drive_file_rounded
                                      : Icons.terminal_rounded,
                                  size: 16,
                                  color: isDirectory
                                      ? Colors.amber
                                      : isPath
                                      ? Colors.blue.shade300
                                      : Colors.green.shade300,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  suggestion,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 14,
                                    fontFamily: 'monospace',
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (!isPath)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'cmd',
                                    style: TextStyle(
                                      color: Colors.green.shade300,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              if (isDirectory)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'dir',
                                    style: TextStyle(
                                      color: Colors.amber.shade300,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              if (isPath && !isDirectory)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'file',
                                    style: TextStyle(
                                      color: Colors.blue.shade300,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Sessions as tabs under the app bar; long-press a tab to restart, stop or
  /// delete it.
  PreferredSizeWidget _buildSessionTabs(TerminalSessionState state, AppTheme appTheme) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(36),
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          children: [
            for (final session in state.sessions)
              Builder(
                builder: (tabContext) {
                  final isActive = session.id == state.activeSessionId;
                  return GestureDetector(
                    onTap: () => _sessionBloc.add(SetActiveTerminalSession(session.id)),
                    onLongPressStart: (details) => _showSessionMenu(session, details.globalPosition),
                    child: Container(
                      margin: const EdgeInsets.only(right: 4, bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isActive ? appTheme.editorPageToolSelectedBgColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        session.isRunning ? session.title : '${session.title} (stopped)',
                        style: TextStyle(
                          color: isActive ? appTheme.selectScreenCardTextColor : appTheme.editorPageToolColor,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSessionMenu(TerminalSessionMeta session, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'restart', child: Text('Restart')),
        PopupMenuItem(value: 'stop', enabled: session.isRunning, child: const Text('Stop')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    switch (action) {
      case 'restart':
        await _restartSession(session.id);
      case 'stop':
        _terminateSession(session.id);
      case 'delete':
        _deleteSession(session.id);
    }
  }

  Widget _buildSessionDrawer(TerminalSessionState state, AppTheme appTheme) {
    return Drawer(
      backgroundColor: appTheme.selectScreenDrawerBg,
      surfaceTintColor: Colors.transparent,
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: appTheme.editorPageDrawerBg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Terminal Sessions',
                  style: TextStyle(
                    color: appTheme.selectScreenCardTextColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${state.sessions.length} active tabs',
                  style: TextStyle(
                    color: appTheme.editorPageToolColor,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.sessions.length,
              itemBuilder: (context, index) {
                final session = state.sessions[index];
                final isActive = session.id == state.activeSessionId;

                return ListTile(
                  leading: Icon(
                    session.isRunning ? Icons.terminal : Icons.pause_circle,
                    color: session.isRunning
                        ? appTheme.editorPageToolSelectedColor
                        : appTheme.editorPageToolColor,
                  ),
                  title: Text(
                    session.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: appTheme.selectScreenCardTextColor),
                  ),
                  subtitle: Text(
                    session.isRunning ? 'Running' : 'Stopped',
                    style: TextStyle(color: appTheme.editorPageToolColor),
                  ),
                  selected: isActive,
                  selectedTileColor: appTheme.editorPageToolSelectedBgColor,
                  onTap: () {
                    _sessionBloc.add(SetActiveTerminalSession(session.id));
                    Navigator.of(context).pop();
                  },
                  trailing: Wrap(
                    spacing: 2,
                    children: [
                      IconButton(
                        tooltip: 'Restart session',
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _restartSession(session.id),
                        icon: Icon(
                          Icons.refresh,
                          size: 18,
                          color: appTheme.editorPageToolColor,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Stop session',
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: session.isRunning
                            ? () => _terminateSession(session.id)
                            : null,
                        icon: Icon(
                          Icons.stop_circle_outlined,
                          size: 18,
                          color: session.isRunning
                              ? appTheme.editorPageToolColor
                              : appTheme.editorPageToolColor.withValues(
                                  alpha: 0.45,
                                ),
                        ),
                      ),
                      IconButton(
                          tooltip: AppLocalizations.of(context)!.delete,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _deleteSession(session.id),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: appTheme.editorPageToolColor,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TerminalSessionBloc, TerminalSessionState>(
      listenWhen: (previous, current) => previous.activeSessionId != current.activeSessionId,
      listener: (context, state) {
        _hideSelectionToolbar();
        _suggestionsNotifier.value = null;
        _hasSelection = false;
      },
      child: BlocBuilder<TerminalSessionBloc, TerminalSessionState>(
        builder: (context, state) {
          final activeRuntime = _activeRuntime();
          final appTheme = context.watch<AppThemeBloc>().state.appTheme;
          final configState = context.watch<ConfigBloc>().state;
          final activeTerminalTheme = terminalThemePresetById(
            configState.codeForgeConfig['terminalTheme']?.toString(),
          );
          final terminalContent = activeRuntime == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: TerminalView(
                            activeRuntime.terminal,
                            // While text is selected, taps must not open the keyboard: it
                            // resizes the terminal and clears the selection.
                            readOnly: widget.readOnly || _hasSelection,
                            padding: EdgeInsets.zero,
                            controller: activeRuntime.controller,
                            autofocus: true,
                            keyboardType: TextInputType.multiline,
                            theme: activeTerminalTheme.theme,
                            textStyle: TerminalStyle(
                              fontSize: state.fontSize
                            ),
                          ),
                        ),
                        if (widget.showKeyboardMenu)
                          TerminalKeyboardMenu(
                            onSendSequence: sendToPty,
                            onModifierChanged:
                              (ctrl, alt, shift, resetCallback) {
                                _setTerminalOutputWithAutocomplete(
                                  ctrl: ctrl,
                                  alt: alt,
                                  shift: shift,
                                  resetCallback: resetCallback,
                                );
                              },
                          ),
                      ],
                    ),
                    _buildSuggestionBox(),
                  ],
                );

          if (!widget.useScaffold) {
            return terminalContent;
          }

          return Scaffold(
            appBar: AppBar(
              bottom: kTerminalSessionTabs ? _buildSessionTabs(state, appTheme) : null,
              leading: kTerminalSessionTabs ? null : Builder(
                builder: (context) {
                  final sessionCount = state.sessions.length;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        tooltip: 'Open sessions drawer',
                        icon: const Icon(Icons.menu),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                      if (sessionCount > 0)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: appTheme.editorPageToolSelectedBgColor,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              sessionCount > 99 ? '99+' : '$sessionCount',
                              style: TextStyle(
                                color: appTheme.editorPageToolSelectedColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              title: Text(
                activeRuntime?.title ?? 'Terminal',
                style: TextStyle(
                  color: appTheme.selectScreenCardTextColor
                ),
              ),
              actions: [
                if (!kTerminalSessionTabs) IconButton(
                  onPressed: () => _onTerminalFontSizeChanged(state.fontSize - 1),
                  icon: Icon(Icons.zoom_out)
                ),
                if (!kTerminalSessionTabs) IconButton(
                  onPressed: () => _onTerminalFontSizeChanged(state.fontSize + 1),
                  icon: Icon(Icons.zoom_in)
                ),
                IconButton(
                  tooltip: 'New session',
                  onPressed: () => _createSession(
                    makeActive: true,
                    showFeedback: true,
                  ),
                  icon: Row(
                    children: [
                      Icon(Icons.add),
                      if(sshServerList.isNotEmpty || termuxInfo != null) MenuAnchor(
                        style: MenuStyle(
                          backgroundColor: WidgetStatePropertyAll(appTheme.selectScreenCardsBg),
                          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: .circular(6)))
                        ),
                        animated: true,
                        onAnimationStatusChanged: (status) {
                          _terminalSelectionStatus = status;
                        },
                        menuChildren: [
                          ...sshServerList.map((server) =>
                            MenuItemButton(
                              onPressed: () {
                                _createSession(
                                  makeActive: true,
                                  showFeedback: true,
                                  externalServer: server
                                );
                              },
                              leadingIcon: Padding(
                                padding: const EdgeInsets.only(left: 3),
                                child: FaIcon(
                                  FontAwesomeIcons.server,
                                  color: appTheme.selectScreenCardTextColor,
                                  size: 20
                                ),
                              ),
                              child: Text(
                                server.name,
                                style: TextStyle(
                                  color: appTheme.selectScreenCardTextColor
                                )
                              ),
                            )
                          ),

                          if(termuxInfo != null && termuxInfo!.isConnected)
                          MenuItemButton(
                            onPressed: () {
                              _createSession(
                                makeActive: true,
                                showFeedback: true,
                                externalServer: termuxInfo
                              );
                            },
                            leadingIcon: SvgPicture.asset(
                              "assets/icons/Termux.svg",
                              height: 20,
                              width: 20
                            ),
                            child: Text(
                              termuxInfo!.name,
                              style: TextStyle(
                                color: appTheme.selectScreenCardTextColor
                              )
                            ),
                          )
                        ],
                        builder: (context, controller, child) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () {
                              if(_terminalSelectionStatus.isForwardOrCompleted){
                                controller.close();
                              } else {
                                controller.open();
                              }
                            },
                            child: Icon(
                              Icons.arrow_drop_down_rounded,
                              color: appTheme.selectScreenCardTextColor
                                      
                            )
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (kTerminalSessionTabs)
                  PopupMenuButton<VoidCallback>(
                    tooltip: 'More',
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: () {
                          if (activeRuntime == null) return;
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => TerminalTextScreen(runtime: activeRuntime),
                          ));
                        },
                        child: const Text('Select text'),
                      ),
                      PopupMenuItem(value: () => _copyText(activeRuntime?.lastOutput), child: const Text('Copy last output')),
                      PopupMenuItem(value: () => _copyText(activeRuntime?.allText), child: const Text('Copy all')),
                      const PopupMenuDivider(),
                      PopupMenuItem(value: () => _onTerminalFontSizeChanged(state.fontSize + 1), child: const Text('Zoom in')),
                      PopupMenuItem(value: () => _onTerminalFontSizeChanged(state.fontSize - 1), child: const Text('Zoom out')),
                    ],
                  ),
              ],
            ),
            drawer: kTerminalSessionTabs ? null : _buildSessionDrawer(state, appTheme),
            body: terminalContent,
          );
        },
      ),
    );
  }
}

class TerminalKeyboardMenu extends StatefulWidget {
  final Function(String) onSendSequence;
  final Function(bool ctrl, bool alt, bool shift, VoidCallback resetCallback)
  onModifierChanged;

  const TerminalKeyboardMenu({
    super.key,
    required this.onSendSequence,
    required this.onModifierChanged,
  });

  @override
  State<TerminalKeyboardMenu> createState() => _TerminalKeyboardMenuState();
}

class _TerminalKeyboardMenuState extends State<TerminalKeyboardMenu> {
  bool isCtrlActive = false;
  bool isAltActive = false;
  bool isShiftActive = false;

  void _resetModifiers() {
    setState(() {
      isCtrlActive = false;
      isAltActive = false;
      isShiftActive = false;
    });
  }

  void _toggleCtrl() {
    setState(() {
      isCtrlActive = !isCtrlActive;
      if (isCtrlActive) {
        isAltActive = false;
        isShiftActive = false;
      }
    });
    widget.onModifierChanged(
      isCtrlActive,
      isAltActive,
      isShiftActive,
      _resetModifiers,
    );
  }

  void _toggleAlt() {
    setState(() {
      isAltActive = !isAltActive;
      if (isAltActive) {
        isCtrlActive = false;
        isShiftActive = false;
      }
    });
    widget.onModifierChanged(
      isCtrlActive,
      isAltActive,
      isShiftActive,
      _resetModifiers,
    );
  }

  void _toggleShift() {
    setState(() {
      isShiftActive = !isShiftActive;
      if (isShiftActive) {
        isCtrlActive = false;
        isAltActive = false;
      }
    });
    widget.onModifierChanged(
      isCtrlActive,
      isAltActive,
      isShiftActive,
      _resetModifiers,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, VoidCallback onTap, {bool active = false, IconData? icon}) => Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          color: active ? scheme.onSurface.withValues(alpha: 0.2) : null,
          child: icon != null
              ? Icon(icon, size: 18, color: scheme.onSurface)
              : Text(
                  label,
                  style: TextStyle(
                    color: active ? Colors.yellow : scheme.onSurface,
                    fontSize: 13,
                    fontFamily: 'jetBrainsMono',
                  ),
                ),
        ),
      ),
    );
    void send(String sequence) => widget.onSendSequence(sequence);
    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Row(
            children: [
              key('ESC', () => send('\x1b')),
              key('TAB', () => send('\t')),
              key('CTRL', _toggleCtrl, active: isCtrlActive),
              key('ALT', _toggleAlt, active: isAltActive),
              key('SHIFT', _toggleShift, active: isShiftActive),
              key('HOME', () => send('\x1b[H')),
              key('↑', () => send('\x1b[A'), icon: Icons.arrow_upward),
              key('END', () => send('\x1b[F')),
            ],
          ),
          Row(
            children: [
              key('|', () => send('|')),
              key('-', () => send('-')),
              key('/', () => send('/')),
              key('~', () => send('~')),
              key('←', () => send('\x1b[D'), icon: Icons.arrow_back),
              key('↓', () => send('\x1b[B'), icon: Icons.arrow_downward),
              key('→', () => send('\x1b[C'), icon: Icons.arrow_forward),
            ],
          ),
        ],
      ),
    );
  }
}

/// The session's text (scrollback included) as plain, selectable text, with
/// no keyboard: the reliable way to copy on a phone.
class TerminalTextScreen extends StatelessWidget {
  final TerminalRuntime runtime;

  /// More than this many lines makes selection sluggish on small phones.
  static const maxLines = 3000;

  const TerminalTextScreen({super.key, required this.runtime});

  void _copy(BuildContext context, String? text) {
    final messenger = ScaffoldMessenger.of(context);
    if (text == null || text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Nothing to copy'), duration: Duration(seconds: 1)));
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final all = runtime.allText;
    final lines = all.split('\n');
    final shown = lines.length > maxLines ? lines.sublist(lines.length - maxLines).join('\n') : all;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select text'),
        actions: [
          TextButton(onPressed: () => _copy(context, runtime.lastOutput), child: const Text('Last output')),
          TextButton(onPressed: () => _copy(context, all), child: const Text('Copy all')),
        ],
      ),
      body: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(8),
        child: SelectableText(
          shown,
          style: TextStyle(fontFamily: 'jetBrainsMono', fontSize: 12, color: scheme.onSurface, height: 1.3),
        ),
      ),
    );
  }
}
